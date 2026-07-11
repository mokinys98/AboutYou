import { Hono, type MiddlewareHandler } from "hono";
import { cors } from "hono/cors";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { CatalogFiltersSchema, PRODUCT_DETAIL_PARSER_VERSION, isAllowedAboutYouUrl } from "@catalog/shared";
import { z } from "zod";

type Bindings = {
  ALLOWED_ORIGIN: string;
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  WEB_APP_URL?: string;
};
type SchedulerBindings = Bindings & {
  GITHUB_TOKEN: string;
  GITHUB_OWNER: string;
  GITHUB_REPO: string;
  GITHUB_REF: string;
};
type Variables = { db: SupabaseClient; member: { userId: string; role: "admin" | "viewer"; email: string } };
type DashboardQueryResult<T = unknown> = { data: T | null; error: { message: string } | null };

export const EXCLUDED_BASICS_CATEGORIES = [
  "Apatiniai",
  "Apatinės kelnės",
  "Apatiniai marškinėliai",
  "Kojinės",
  "Naktiniai drabužiai",
  "Vonios chalatai"
];

export const app = new Hono<{ Bindings: Bindings; Variables: Variables }>();
const jwks = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

const WORKFLOW_BY_CRON: Readonly<Record<string, string>> = {
  "17 */6 * * *": "sync-catalog.yml",
  "47 * * * *": "sync-product-metadata.yml"
};

const DEV_ORIGINS = new Set([
  "http://localhost:3000",
  "http://localhost:3001",
  "http://localhost:3002",
  "http://127.0.0.1:3000",
  "http://127.0.0.1:3001",
  "http://127.0.0.1:3002"
]);

export function allowedCorsOrigin(origin: string, allowedOrigin: string): string | null {
  const configuredOrigins = allowedOrigin.split(",").map((value) => value.trim()).filter(Boolean);
  return configuredOrigins.includes(origin) || DEV_ORIGINS.has(origin) ? origin : null;
}

app.use("*", async (c, next) => cors({
  origin: (origin, context) => allowedCorsOrigin(origin, context.env.ALLOWED_ORIGIN),
  allowHeaders: ["Authorization", "Content-Type"],
  exposeHeaders: ["ETag"]
})(c, next));
app.get("/health", (c) => c.json({ ok: true }));

app.use("/v1/*", async (c, next) => {
  const token = c.req.header("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) return c.json({ error: "Prisijungimas būtinas" }, 401);
  if (!c.env.SUPABASE_URL || !c.env.SUPABASE_SERVICE_ROLE_KEY) {
    return c.json({ error: "API autentifikacija nesukonfigūruota" }, 503);
  }
  let userId: string;
  try {
    let keySet = jwks.get(c.env.SUPABASE_URL);
    if (!keySet) {
      keySet = createRemoteJWKSet(new URL(`${c.env.SUPABASE_URL}/auth/v1/.well-known/jwks.json`));
      jwks.set(c.env.SUPABASE_URL, keySet);
    }
    const { payload } = await jwtVerify(token, keySet, { issuer: `${c.env.SUPABASE_URL}/auth/v1` });
    if (!payload.sub) throw new Error("JWT neturi sub");
    userId = payload.sub;
  } catch { return c.json({ error: "Neteisinga arba pasibaigusi sesija" }, 401); }
  const db = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: member, error } = await db.from("team_members").select("email,role,active,accepted_at").eq("user_id", userId).eq("active", true).maybeSingle();
  if (error) return c.json({ error: "Komandos narystės patikrinti nepavyko" }, 503);
  if (!member) return c.json({ error: "Naudotojas nepriklauso komandai" }, 403);
  if (!member.accepted_at && c.req.path !== "/v1/users/accept-invite") {
    return c.json({ error: "Pirmiausia užbaikite kvietimą ir susikurkite slaptažodį" }, 403);
  }
  c.set("db", db);
  c.set("member", { userId, role: member.role, email: member.email });
  await next();
});

const requireAdmin: MiddlewareHandler<{ Bindings: Bindings; Variables: Variables }> = async (c, next) => {
  if (c.get("member").role !== "admin") return c.json({ error: "Reikalinga administratoriaus rolė" }, 403);
  await next();
};

app.get("/v1/me", (c) => c.json(c.get("member")));

const InviteMemberInput = z.object({
  email: z.string().trim().toLowerCase().email().max(320)
});

export function teamMemberStatus(member: { active: boolean; accepted_at: string | null }): "disabled" | "pending" | "active" {
  if (!member.active) return "disabled";
  return member.accepted_at ? "active" : "pending";
}

export function inviteErrorResponse(error: { message: string; status?: number; code?: string }): { status: 400 | 409 | 429 | 502; message: string } {
  const message = error.message.toLowerCase();
  if (error.status === 429 || message.includes("rate limit")) {
    return { status: 429, message: "Viršytas kvietimų siuntimo limitas. Bandykite vėliau." };
  }
  if (message.includes("already") || message.includes("registered") || message.includes("exists")) {
    return { status: 409, message: "Toks naudotojas jau egzistuoja." };
  }
  if (message.includes("smtp") || message.includes("email") || message.includes("mail")) {
    return { status: 502, message: "Kvietimo laiško išsiųsti nepavyko. Patikrinkite el. pašto siuntimo nustatymus." };
  }
  return { status: 400, message: "Kvietimo išsiųsti nepavyko." };
}

app.get("/v1/admin/users", requireAdmin, async (c) => {
  const { data, error } = await c.get("db")
    .from("team_members")
    .select("email,role,active,invited_at,accepted_at")
    .order("created_at", { ascending: false });
  if (error) return c.json({ error: "Vartotojų sąrašo įkelti nepavyko." }, 500);
  return c.json((data ?? []).map((member) => ({
    email: member.email,
    role: member.role,
    status: teamMemberStatus(member),
    invitedAt: member.invited_at,
    acceptedAt: member.accepted_at
  })));
});

app.post("/v1/admin/users/invite", requireAdmin, async (c) => {
  const input = InviteMemberInput.safeParse(await c.req.json().catch(() => null));
  if (!input.success) return c.json({ error: "Įveskite galiojantį el. pašto adresą." }, 400);

  const db = c.get("db");
  const { data: existing, error: lookupError } = await db
    .from("team_members")
    .select("user_id")
    .ilike("email", input.data.email)
    .maybeSingle();
  if (lookupError) return c.json({ error: "Vartotojo patikrinti nepavyko." }, 500);
  if (existing) return c.json({ error: "Toks komandos narys jau egzistuoja." }, 409);

  const webAppUrl = c.env.WEB_APP_URL?.replace(/\/$/, "");
  if (!webAppUrl) return c.json({ error: "Kvietimų siuntimas nesukonfigūruotas." }, 503);

  const { data: invited, error: inviteError } = await db.auth.admin.inviteUserByEmail(input.data.email, {
    redirectTo: `${webAppUrl}/auth/invite`
  });
  if (inviteError || !invited.user) {
    const mapped = inviteErrorResponse(inviteError ?? { message: "Invite user missing" });
    return c.json({ error: mapped.message }, mapped.status);
  }

  const now = new Date().toISOString();
  const { error: insertError } = await db.from("team_members").insert({
    user_id: invited.user.id,
    email: input.data.email,
    role: "viewer",
    active: true,
    invited_at: now,
    accepted_at: null,
    invited_by: c.get("member").userId
  });
  if (insertError) {
    const { error: cleanupError } = await db.auth.admin.deleteUser(invited.user.id);
    if (cleanupError) console.error(JSON.stringify({ event: "invite_cleanup_failed", userId: invited.user.id, error: cleanupError.message }));
    return c.json({ error: "Kvietimas išsiųstas, tačiau vartotojo sukurti nepavyko. Bandykite dar kartą." }, 500);
  }

  console.log(JSON.stringify({ event: "team_member_invited", userId: invited.user.id, invitedBy: c.get("member").userId }));
  return c.json({
    email: input.data.email,
    role: "viewer",
    status: "pending",
    invitedAt: now,
    acceptedAt: null
  }, 201);
});

app.post("/v1/users/accept-invite", async (c) => {
  const member = c.get("member");
  const { data, error } = await c.get("db")
    .from("team_members")
    .update({ accepted_at: new Date().toISOString() })
    .eq("user_id", member.userId)
    .is("accepted_at", null)
    .select("accepted_at")
    .maybeSingle();
  if (error) return c.json({ error: "Kvietimo priėmimo pažymėti nepavyko." }, 500);
  return c.json({ accepted: true, acceptedAt: data?.accepted_at ?? null });
});

app.get("/v1/catalog", async (c) => {
  const parsed = parseFilters(c.req.query());
  if (!parsed.success) return c.json({ error: parsed.error.flatten() }, 400);
  const filters = parsed.data;
  const cacheUrl = catalogCacheUrl(c.req.url, c.get("member").userId);
  const cacheKey = new Request(cacheUrl, { method: "GET" });
  const edgeCache = getEdgeCache();
  const cached = await edgeCache.match(cacheKey);
  if (cached) return cached;

  let query = c.get("db").from("catalog_items").select("*", filters.cursor ? undefined : { count: "exact" });
  if (filters.brands.length) query = query.in("brand", filters.brands);
  if (filters.sources.length) query = query.in("source", filters.sources);
  if (filters.colors.length) query = query.in("color_family", filters.colors);
  if (filters.colorShades.length) query = query.in("color_shade", filters.colorShades);
  if (filters.categoryPath) query = query.overlaps("category_paths", [filters.categoryPath]);
  else if (filters.categories.length) query = query.overlaps("categories", filters.categories);
  if (filters.sizes.length) query = query.overlaps("sizes", filters.sizes);
  if (filters.otherSizes.length) query = query.overlaps("other_sizes", filters.otherSizes);
  if (filters.materials.length) query = query.overlaps("materials", filters.materials);
  if (filters.patterns.length) query = query.overlaps("patterns", filters.patterns);
  if (filters.features.length) query = query.overlaps("features", filters.features);
  if (filters.styles.length) query = query.overlaps("styles", filters.styles);
  if (filters.productTypes.length) query = query.overlaps("product_types", filters.productTypes);
  if (filters.isPremium) query = query.eq("is_premium", true);
  if (filters.excludeBasics) {
    const excludedBasics = postgresArrayLiteral(EXCLUDED_BASICS_CATEGORIES);
    query = query.not("category_names", "ov", excludedBasics).not("categories", "ov", excludedBasics);
  }
  if (filters.priceMin !== undefined) query = query.gte("current_price", filters.priceMin);
  if (filters.priceMax !== undefined) query = query.lte("current_price", filters.priceMax);
  if (filters.discountMin !== undefined) query = query.gte("discount_pct", filters.discountMin);
  if (filters.belowObserved30d) {
    query = query.eq(priceComparisonColumn(filters.priceComparison), true);
  }
  if (filters.newOnly) query = query.gte("first_seen_at", newestCatalogCutoff());

  const cursor = decodeCursor(filters.cursor);
  const sort = sortDefinition(filters.sort);
  query = query.order(sort.column, { ascending: sort.ascending }).order("id", { ascending: sort.ascending }).limit(filters.limit + 1);
  if (cursor) {
    const operator = sort.ascending ? "gt" : "lt";
    query = query.or(`${sort.column}.${operator}.${cursor.value},and(${sort.column}.eq.${cursor.value},id.${operator}.${cursor.id})`);
  }
  const { data, error, count } = await query;
  if (error) return c.json({ error: error.message }, 500);
  const rows = data ?? [];
  const hasNext = rows.length > filters.limit;
  const pageRows = rows.slice(0, filters.limit);
  const watched = await watchedProductIds(c.get("db"), c.get("member").userId, pageRows.map((row) => row.id));
  const items = pageRows.map((row) => mapCatalogItem(row, watched.has(row.id)));
  const last = rows[Math.min(rows.length, filters.limit) - 1];
  const body = JSON.stringify({
    items,
    nextCursor: hasNext && last ? encodeCursor({ value: last[sort.column], id: last.id }) : null,
    ...(count === null ? {} : { totalCount: count })
  });
  const etag = `"${await sha256(body)}"`;
  if (c.req.header("If-None-Match") === etag) return c.body(null, 304, { ETag: etag });
  const response = new Response(body, { headers: { "content-type": "application/json", "cache-control": "private, max-age=0", ETag: etag } });
  c.executionCtx.waitUntil(edgeCache.put(cacheKey, new Response(body, { headers: { "content-type": "application/json", "cache-control": "max-age=300" } })));
  return response;
});

app.get("/v1/catalog/facets", async (c) => {
  const parsed = parseFilters(c.req.query());
  if (!parsed.success) return c.json({ error: parsed.error.flatten() }, 400);
  const cacheUrl = new URL(c.req.url);
  cacheUrl.hostname = "facet-cache.internal";
  cacheUrl.searchParams.sort();
  const cacheKey = new Request(cacheUrl, { method: "GET" });
  const edgeCache = getEdgeCache();
  const cached = await edgeCache.match(cacheKey);
  if (cached) return cached;
  const { sort: _sort, cursor: _cursor, limit: _limit, ...facetFilters } = parsed.data;
  const facetFunction = facetFilters.newOnly ? "catalog_news_facets" : "catalog_facets";
  const effectiveFacetFilters = {
    ...facetFilters,
    categories: facetFilters.categoryPath ? [facetFilters.categoryPath] : facetFilters.categories
  };
  const [{ data, error }, { data: categoryFacets, error: categoryError }] = await Promise.all([
    c.get("db").rpc(facetFunction, { p_filters: effectiveFacetFilters }),
    c.get("db").rpc("catalog_category_facets", { p_filters: effectiveFacetFilters })
  ]);
  if (error) {
    console.error("[catalog/facets]", { code: error.code, message: error.message, details: error.details, hint: error.hint });
    return c.json({ error: error.message }, 500);
  }
  if (categoryError) {
    console.error("[catalog/category-facets]", { code: categoryError.code, message: categoryError.message, details: categoryError.details, hint: categoryError.hint });
    return c.json({ error: categoryError.message }, 500);
  }
  const body = JSON.stringify({ ...(data ?? {}), categories: categoryFacets ?? [] });
  c.executionCtx.waitUntil(edgeCache.put(cacheKey, new Response(body, { headers: { "content-type": "application/json", "cache-control": "max-age=300" } })));
  return new Response(body, { headers: { "content-type": "application/json", "cache-control": "private, max-age=0" } });
});

app.get("/v1/products/:id", async (c) => {
  const id = c.req.param("id");
  const [
    { data: product, error },
    { data: history },
    { data: priceChanges, error: priceChangesError },
    { data: watch },
    { data: detailSync, error: detailSyncError },
    { data: detailSections, error: detailSectionsError },
    { data: colorOptions, error: colorOptionsError },
    { data: sizeOptions, error: sizeOptionsError }
  ] = await Promise.all([
    c.get("db").from("catalog_items").select("*").eq("id", id).maybeSingle(),
    c.get("db").from("daily_prices").select("observed_date,min_price,max_price,last_price,source_lpl_30").eq("product_id", id).order("observed_date"),
    c.get("db").from("price_changes").select("observed_at,price,original_price,source_lpl_30").eq("product_id", id).order("observed_at", { ascending: false }),
    c.get("db").from("product_watches").select("product_id").eq("user_id", c.get("member").userId).eq("product_id", id).maybeSingle(),
    c.get("db").from("product_detail_sync").select("status,parser_version,static_synced_at,availability_synced_at").eq("product_id", id).maybeSingle(),
    c.get("db").from("product_detail_sections").select("section_key,source_label,status,items,position").eq("product_id", id).order("position"),
    c.get("db").from("product_color_options").select("external_id,label,url,selected,position").eq("product_id", id).order("position"),
    c.get("db").from("product_size_options").select("external_id,label,size_group,selected,selectable,availability,position").eq("product_id", id).order("position")
  ]);
  if (error) return c.json({ error: error.message }, 500);
  if (priceChangesError) return c.json({ error: priceChangesError.message }, 500);
  const detailError = detailSyncError ?? detailSectionsError ?? colorOptionsError ?? sizeOptionsError;
  if (detailError) return c.json({ error: detailError.message }, 500);
  if (!product) return c.json({ error: "Produktas nerastas" }, 404);
  return c.json({
    ...mapCatalogItem(product, Boolean(watch)),
    detail: mapProductDetail(detailSync, detailSections ?? [], colorOptions ?? [], sizeOptions ?? []),
    history: history ?? [], priceChanges: priceChanges ?? []
  });
});

app.get("/v1/products/:id/debug", requireAdmin, async (c) => {
  const id = z.string().uuid().safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "Neteisingas produkto ID" }, 400);
  const [
    { data: product, error },
    { data: detailSync, error: detailSyncError },
    { data: detailSections, error: detailSectionsError },
    { data: colorOptions, error: colorOptionsError },
    { data: sizeOptions, error: sizeOptionsError },
    { data: raw, error: rawError }
  ] = await Promise.all([
    c.get("db").from("catalog_items").select("*").eq("id", id.data).maybeSingle(),
    c.get("db").from("product_detail_sync").select("status,parser_version,static_synced_at,availability_synced_at").eq("product_id", id.data).maybeSingle(),
    c.get("db").from("product_detail_sections").select("section_key,source_label,status,items,position").eq("product_id", id.data).order("position"),
    c.get("db").from("product_color_options").select("external_id,label,url,selected,position").eq("product_id", id.data).order("position"),
    c.get("db").from("product_size_options").select("external_id,label,size_group,selected,selectable,availability,position").eq("product_id", id.data).order("position"),
    c.get("db").from("product_detail_raw").select("payload,payload_hash,fetched_at,source_endpoint,parser_version").eq("product_id", id.data).maybeSingle()
  ]);
  const queryError = error ?? detailSyncError ?? detailSectionsError ?? colorOptionsError ?? sizeOptionsError ?? rawError;
  if (queryError) return c.json({ error: queryError.message }, 500);
  if (!product) return c.json({ error: "Produktas nerastas" }, 404);
  return c.json(mapProductDebug(product, detailSync, detailSections ?? [], colorOptions ?? [], sizeOptions ?? [], raw));
});

app.get("/v1/watchlist", async (c) => {
  const page = z.object({ cursor: z.coerce.number().int().nonnegative().default(0), limit: z.coerce.number().int().min(1).max(100).default(48) }).safeParse(c.req.query());
  if (!page.success) return c.json({ error: page.error.flatten() }, 400);
  const { cursor, limit } = page.data;
  const { data: watches, error } = await c.get("db").from("product_watches").select("product_id,created_at")
    .eq("user_id", c.get("member").userId).order("created_at", { ascending: false }).order("product_id", { ascending: false })
    .range(cursor, cursor + limit);
  if (error) return c.json({ error: error.message }, 500);
  const pageWatches = (watches ?? []).slice(0, limit);
  const ids = pageWatches.map((watch) => watch.product_id);
  if (!ids.length) return c.json({ items: [], nextCursor: null });
  const { data: rows, error: catalogError } = await c.get("db").from("catalog_items").select("*").in("id", ids);
  if (catalogError) return c.json({ error: catalogError.message }, 500);
  const byId = new Map((rows ?? []).map((row) => [row.id, row]));
  const items = ids.flatMap((id) => byId.has(id) ? [mapCatalogItem(byId.get(id)!, true)] : []);
  return c.json({ items, nextCursor: (watches?.length ?? 0) > limit ? String(cursor + limit) : null });
});

app.put("/v1/watchlist/:productId", async (c) => {
  const productId = z.string().uuid().safeParse(c.req.param("productId"));
  if (!productId.success) return c.json({ error: "Neteisingas produkto ID" }, 400);
  const { error } = await c.get("db").from("product_watches").upsert(
    { user_id: c.get("member").userId, product_id: productId.data },
    { onConflict: "user_id,product_id", ignoreDuplicates: true }
  );
  if (error?.code === "23503") return c.json({ error: "Produktas nerastas" }, 404);
  return error ? c.json({ error: error.message }, 500) : c.json({ watched: true });
});

app.delete("/v1/watchlist/:productId", async (c) => {
  const productId = z.string().uuid().safeParse(c.req.param("productId"));
  if (!productId.success) return c.json({ error: "Neteisingas produkto ID" }, 400);
  const { error } = await c.get("db").from("product_watches").delete()
    .eq("user_id", c.get("member").userId).eq("product_id", productId.data);
  return error ? c.json({ error: error.message }, 500) : c.json({ watched: false });
});

app.get("/v1/sync-targets", requireAdmin, async (c) => {
  const { data, error } = await c.get("db").from("sync_targets").select("*,sources(slug,name)").order("priority");
  return error ? c.json({ error: error.message }, 500) : c.json(data);
});

app.get("/v1/admin/dashboard", requireAdmin, async (c) => {
  const db = c.get("db");
  let totalProducts: number;
  let activeProducts: number;
  let catalogProducts: number;
  let metadataProducts: number;
  let premiumProducts: number;
  let newProducts: number;
  let belowObservedProducts: number;
  let enabledTargets: number;
  let disabledTargets: number;
  let categories: DashboardQueryResult<Array<Record<string, unknown>>>;
  let metadataSummary: DashboardQueryResult<Record<string, unknown>>;
  let latestRuns: DashboardQueryResult<Array<Record<string, unknown>>>;
  try {
    [
      totalProducts,
      activeProducts,
      catalogProducts,
      metadataProducts,
      premiumProducts,
      newProducts,
      belowObservedProducts,
      categories,
      metadataSummary,
      enabledTargets,
      disabledTargets,
      latestRuns
    ] = await Promise.all([
      counted(db.from("products").select("id", { count: "exact", head: true })),
      counted(db.from("products").select("id", { count: "exact", head: true }).eq("active", true)),
      counted(db.from("catalog_items").select("id", { count: "exact", head: true })),
      counted(db.from("products").select("id", { count: "exact", head: true }).eq("active", true).not("metadata_updated_at", "is", null)),
      counted(db.from("catalog_items").select("id", { count: "exact", head: true }).eq("is_premium", true)),
      counted(db.from("catalog_items").select("id", { count: "exact", head: true }).gte("first_seen_at", newestCatalogCutoff())),
      counted(db.from("catalog_items").select("id", { count: "exact", head: true }).eq("below_observed_30d", true)),
      db.rpc("catalog_category_facets", { p_filters: {} }),
      db.rpc("product_detail_sync_summary", { p_parser_version: PRODUCT_DETAIL_PARSER_VERSION }),
      counted(db.from("sync_targets").select("id", { count: "exact", head: true }).eq("enabled", true)),
      counted(db.from("sync_targets").select("id", { count: "exact", head: true }).eq("enabled", false)),
      db.from("sync_runs").select("id,status,started_at,finished_at,products_count,error,sync_targets(label)").order("started_at", { ascending: false }).limit(8)
    ]);
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : "Dashboard statistikos uzkrauti nepavyko";
    return c.json({ error: message }, 500);
  }

  const queryError = categories.error ?? metadataSummary.error ?? latestRuns.error;
  if (queryError) return c.json({ error: queryError.message }, 500);

  return c.json({
    generatedAt: new Date().toISOString(),
    parserVersion: PRODUCT_DETAIL_PARSER_VERSION,
    totals: {
      products: totalProducts,
      activeProducts,
      catalogProducts,
      metadataProducts,
      premiumProducts,
      newProducts,
      belowObservedProducts,
      enabledTargets,
      disabledTargets
    },
    metadata: metadataSummary.data ?? {},
    categories: categories.data ?? [],
    latestRuns: latestRuns.data ?? []
  });
});

const TargetInput = z.object({ kind: z.enum(["category", "brand", "search"]), label: z.string().min(2).max(100), url: z.string().url(), priority: z.number().int().min(0).max(1000).default(100), enabled: z.boolean().default(true) });
app.post("/v1/sync-targets", requireAdmin, async (c) => {
  const input = TargetInput.safeParse(await c.req.json().catch(() => null));
  if (!input.success || !isAllowedAboutYouUrl(input.data.url)) return c.json({ error: "Neteisingi duomenys arba URL" }, 400);
  const { data: source } = await c.get("db").from("sources").select("id").eq("slug", "aboutyou-lt").single();
  const { data, error } = await c.get("db").from("sync_targets").insert({ ...input.data, source_id: source?.id }).select().single();
  return error ? c.json({ error: error.message }, 400) : c.json(data, 201);
});

app.patch("/v1/sync-targets/:id", requireAdmin, async (c) => {
  const id = z.string().uuid().safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "Neteisingas grupės ID" }, 400);
  const input = TargetInput.partial().safeParse(await c.req.json().catch(() => null));
  if (!input.success || (input.data.url && !isAllowedAboutYouUrl(input.data.url))) return c.json({ error: "Neteisingi duomenys" }, 400);
  const { data, error } = await c.get("db").from("sync_targets").update(input.data).eq("id", id.data).select().maybeSingle();
  if (error) return c.json({ error: error.message }, 400);
  return data ? c.json(data) : c.json({ error: "Grupė nerasta" }, 404);
});

app.delete("/v1/sync-targets/:id", requireAdmin, async (c) => {
  const id = z.string().uuid().safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "Neteisingas grupės ID" }, 400);
  const { data, error } = await c.get("db").rpc("delete_sync_target", { p_target_id: id.data });
  if (error) return c.json({ error: error.message }, 500);
  return data ? c.json({ deleted: true }) : c.json({ error: "Grupė nerasta" }, 404);
});

app.get("/v1/sync-runs", requireAdmin, async (c) => {
  const { data, error } = await c.get("db").from("sync_runs").select("*,sync_targets(label)").order("started_at", { ascending: false }).limit(100);
  return error ? c.json({ error: error.message }, 500) : c.json(data);
});

app.post("/v1/sync-targets/:id/request-sync", requireAdmin, async (c) => {
  const { data, error } = await c.get("db").from("sync_targets").update({ requested_at: new Date().toISOString() }).eq("id", c.req.param("id")).select().single();
  return error ? c.json({ error: error.message }, 400) : c.json({ queued: true, target: data });
});

export function parseFilters(query: Record<string, string>) {
  const list = (value?: string) => value ? value.split(",").map(decodeURIComponent).filter(Boolean) : [];
  return CatalogFiltersSchema.safeParse({
    brands: list(query.brands), sources: list(query.sources), categories: list(query.categories), categoryPath: query.category ? decodeURIComponent(query.category) : undefined, colors: list(query.colors),
    colorShades: list(query.color_shades),
    sizes: list(query.sizes), otherSizes: list(query.other_sizes), materials: list(query.materials),
    patterns: list(query.patterns), features: list(query.features), styles: list(query.styles),
    productTypes: list(query.product_types),
    isPremium: query.premium === "true",
    excludeBasics: query.exclude_basics === "true",
    priceMin: query.price_min ? Number(query.price_min) : undefined, priceMax: query.price_max ? Number(query.price_max) : undefined,
    discountMin: query.discount_min ? Number(query.discount_min) : undefined, belowObserved30d: query.below_observed_30d === "true",
    newOnly: query.new_only === "true",
    priceComparison: query.price_comparison,
    sort: query.sort, cursor: query.cursor, limit: query.limit ? Number(query.limit) : undefined
  });
}

export function priceComparisonColumn(comparison: string): "below_observed_30d" | "below_source_lpl_30d" {
  return comparison === "source_lpl" ? "below_source_lpl_30d" : "below_observed_30d";
}

export function postgresArrayLiteral(values: readonly string[]): string {
  return `{${values.map((value) => `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`).join(",")}}`;
}

export function catalogCacheUrl(requestUrl: string, userId: string): URL {
  const url = new URL(requestUrl);
  url.hostname = "catalog-cache.internal";
  url.searchParams.set("watchlist_user", userId);
  url.searchParams.sort();
  return url;
}

function sortDefinition(sort: string) {
  if (sort === "price_asc") return { column: "current_price", ascending: true } as const;
  if (sort === "price_desc") return { column: "current_price", ascending: false } as const;
  if (sort === "discount_desc") return { column: "discount_pct", ascending: false } as const;
  if (sort === "first_seen") return { column: "first_seen_at", ascending: false } as const;
  return { column: "updated_at", ascending: false } as const;
}

export function newestCatalogCutoff(now = new Date()): string {
  const cutoff = new Date(now);
  cutoff.setUTCDate(cutoff.getUTCDate() - 30);
  return cutoff.toISOString();
}

function mapCatalogItem(row: Record<string, any>, isWatched = false) {
  return { id: row.id, externalId: row.external_id, name: row.name, brand: row.brand, productUrl: row.product_url,
    imageUrls: row.image_urls ?? [], colorOriginal: row.color_original, colorFamily: row.color_family, colorShade: row.color_shade ?? "other", categories: row.category_names ?? row.categories ?? [], categoryPaths: row.category_paths ?? [],
    sizes: row.sizes ?? [], otherSizes: row.other_sizes ?? [], materials: row.materials ?? [], patterns: row.patterns ?? [],
    features: row.features ?? [], styles: row.styles ?? [], productTypes: row.product_types ?? [], isPremium: row.is_premium ?? false,
    source: row.source, currentPrice: row.current_price, originalPrice: row.original_price, sourceLpl30: row.source_lpl_30,
    observedMin30d: row.observed_min_30d, discountPct: Number(row.discount_pct), currency: row.currency, updatedAt: row.updated_at,
    firstSeenAt: row.first_seen_at, isWatched };
}

export function mapProductDebug(
  product: Record<string, any>,
  sync: Record<string, any> | null,
  sections: Array<Record<string, any>>,
  colorOptions: Array<Record<string, any>>,
  sizeOptions: Array<Record<string, any>>,
  raw: Record<string, any> | null
) {
  const mappedProduct = mapCatalogItem(product);
  return {
    product: mappedProduct,
    detail: mapProductDetail(sync, sections, colorOptions, sizeOptions),
    source: inspectProductDebugPayload(raw?.payload, mappedProduct.imageUrls),
    raw: raw ? {
      payload: raw.payload,
      payloadHash: raw.payload_hash,
      fetchedAt: raw.fetched_at,
      sourceEndpoint: raw.source_endpoint,
      parserVersion: raw.parser_version
    } : null
  };
}

export function inspectProductDebugPayload(payload: unknown, storedImageUrls: string[]) {
  const root = asRecord(payload);
  const linksSection = asRecord(root?.linksSection);
  const rawBreadcrumbs = Array.isArray(linksSection?.breadcrumbs) ? linksSection.breadcrumbs : [];
  const breadcrumbs = rawBreadcrumbs.map((item, position) => {
    const breadcrumb = asRecord(item);
    const label = typeof breadcrumb?.label === "string" ? breadcrumb.label.trim() : "";
    const urlContainer = asRecord(breadcrumb?.url);
    const url = typeof urlContainer?.url === "string" && urlContainer.url.trim() ? urlContainer.url.trim() : null;
    const accepted = Boolean(label && url?.startsWith("/c/") && !url.includes("?"));
    let rejectionReason: string | null = null;
    if (!label) rejectionReason = "Trūksta pavadinimo";
    else if (!url) rejectionReason = "Trūksta kategorijos URL";
    else if (!url.startsWith("/c/")) rejectionReason = "Ne kategorijos URL";
    else if (url.includes("?")) rejectionReason = "URL turi filtravimo parametrus";
    return { position, label, url, accepted, rejectionReason };
  });

  const imagesSection = asRecord(root?.imagesSection);
  const rawImages = Array.isArray(imagesSection?.images) ? imagesSection.images : [];
  const stored = new Set(storedImageUrls);
  const images = rawImages.map((item, position) => {
    const imageContainer = asRecord(asRecord(item)?.image);
    const url = typeof imageContainer?.src === "string" && imageContainer.src.trim() ? imageContainer.src.trim() : null;
    return { position, url, stored: Boolean(url && stored.has(url)) };
  });
  return { breadcrumbs, images };
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

export function mapProductDetail(
  sync: Record<string, any> | null,
  sections: Array<Record<string, any>>,
  colorOptions: Array<Record<string, any>>,
  sizeOptions: Array<Record<string, any>>
) {
  const rawStatus = sync?.status;
  const status = rawStatus === "processing" || !rawStatus ? "pending" : rawStatus;
  return {
    status,
    parserVersion: sync?.parser_version ?? 0,
    staticSyncedAt: sync?.static_synced_at ?? null,
    availabilitySyncedAt: sync?.availability_synced_at ?? null,
    sections: sections.map((section) => ({
      key: section.section_key,
      sourceLabel: section.source_label,
      status: section.status,
      items: section.items ?? []
    })),
    colorOptions: colorOptions.map((option) => ({
      externalId: option.external_id,
      label: option.label,
      url: option.url,
      selected: option.selected
    })),
    sizeOptions: sizeOptions.map((option) => ({
      externalId: option.external_id,
      label: option.label,
      group: option.size_group,
      selected: option.selected,
      selectable: option.selectable,
      availability: option.availability
    }))
  };
}

async function watchedProductIds(db: SupabaseClient, userId: string, productIds: string[]): Promise<Set<string>> {
  if (!productIds.length) return new Set();
  const { data } = await db.from("product_watches").select("product_id").eq("user_id", userId).in("product_id", productIds);
  return new Set((data ?? []).map((item) => item.product_id));
}

async function counted<T>(query: PromiseLike<{ count: number | null; error: { message: string } | null }>): Promise<number> {
  const { count, error } = await query;
  if (error) throw new Error(error.message);
  return count ?? 0;
}

function encodeCursor(value: unknown): string { return btoa(JSON.stringify(value)); }
function decodeCursor(value?: string): { value: string | number; id: string } | null { try { return value ? JSON.parse(atob(value)) : null; } catch { return null; } }
async function sha256(value: string): Promise<string> { const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)); return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join(""); }
function getEdgeCache(): Cache { return (caches as unknown as { default: Cache }).default; }

export function workflowForCron(cron: string): string {
  const workflow = WORKFLOW_BY_CRON[cron];
  if (!workflow) throw new Error(`Nežinomas cron grafikas: ${cron}`);
  return workflow;
}

export async function dispatchGitHubWorkflow(
  workflow: string,
  env: SchedulerBindings,
  fetcher: typeof fetch = fetch
): Promise<void> {
  if (!env.GITHUB_TOKEN) throw new Error("Nesukonfigūruotas GITHUB_TOKEN");

  const owner = encodeURIComponent(env.GITHUB_OWNER);
  const repo = encodeURIComponent(env.GITHUB_REPO);
  const workflowId = encodeURIComponent(workflow);
  const response = await fetcher(`https://api.github.com/repos/${owner}/${repo}/actions/workflows/${workflowId}/dispatches`, {
    method: "POST",
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      "Content-Type": "application/json",
      "User-Agent": "aboutyou-private-catalog-api",
      "X-GitHub-Api-Version": "2026-03-10"
    },
    body: JSON.stringify({ ref: env.GITHUB_REF })
  });

  if (!response.ok) {
    const details = (await response.text()).slice(0, 1_000);
    throw new Error(`GitHub workflow ${workflow} paleisti nepavyko (${response.status}): ${details}`);
  }

  console.log(JSON.stringify({
    event: "github_workflow_dispatched",
    workflow,
    repository: `${env.GITHUB_OWNER}/${env.GITHUB_REPO}`,
    ref: env.GITHUB_REF,
    status: response.status
  }));
}

export default {
  fetch(request, env, ctx) {
    return app.fetch(request, env, ctx);
  },
  async scheduled(controller, env) {
    const workflow = workflowForCron(controller.cron);
    try {
      await dispatchGitHubWorkflow(workflow, env);
    } catch (error) {
      console.error(JSON.stringify({
        event: "github_workflow_dispatch_failed",
        workflow,
        cron: controller.cron,
        error: error instanceof Error ? error.message : String(error)
      }));
      throw error;
    }
  }
} satisfies ExportedHandler<SchedulerBindings>;
