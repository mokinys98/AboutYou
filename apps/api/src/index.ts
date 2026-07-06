import { Hono, type MiddlewareHandler } from "hono";
import { cors } from "hono/cors";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { CatalogFiltersSchema, isAllowedAboutYouUrl } from "@catalog/shared";
import { z } from "zod";

type Bindings = {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  ALLOWED_ORIGIN: string;
};
type Variables = { db: SupabaseClient; member: { userId: string; role: "admin" | "viewer"; email: string } };

const app = new Hono<{ Bindings: Bindings; Variables: Variables }>();
const jwks = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

app.use("*", async (c, next) => cors({ origin: c.env.ALLOWED_ORIGIN, allowHeaders: ["Authorization", "Content-Type"], exposeHeaders: ["ETag"] })(c, next));
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
  const { data: member, error } = await db.from("team_members").select("email,role,active").eq("user_id", userId).eq("active", true).maybeSingle();
  if (error) return c.json({ error: "Komandos narystės patikrinti nepavyko" }, 503);
  if (!member) return c.json({ error: "Naudotojas nepriklauso komandai" }, 403);
  c.set("db", db);
  c.set("member", { userId, role: member.role, email: member.email });
  await next();
});

const requireAdmin: MiddlewareHandler<{ Bindings: Bindings; Variables: Variables }> = async (c, next) => {
  if (c.get("member").role !== "admin") return c.json({ error: "Reikalinga administratoriaus rolė" }, 403);
  await next();
};

app.get("/v1/me", (c) => c.json(c.get("member")));

app.get("/v1/catalog", async (c) => {
  const parsed = parseFilters(c.req.query());
  if (!parsed.success) return c.json({ error: parsed.error.flatten() }, 400);
  const filters = parsed.data;
  const cacheUrl = catalogCacheUrl(c.req.url, c.get("member").userId);
  const cacheKey = new Request(cacheUrl, { method: "GET" });
  const edgeCache = getEdgeCache();
  const cached = await edgeCache.match(cacheKey);
  if (cached) return cached;

  let query = c.get("db").from("catalog_items").select("*");
  if (filters.brands.length) query = query.in("brand", filters.brands);
  if (filters.sources.length) query = query.in("source", filters.sources);
  if (filters.colors.length) query = query.in("color_family", filters.colors);
  if (filters.colorShades.length) query = query.in("color_shade", filters.colorShades);
  if (filters.categories.length) query = query.overlaps("categories", filters.categories);
  if (filters.sizes.length) query = query.overlaps("sizes", filters.sizes);
  if (filters.otherSizes.length) query = query.overlaps("other_sizes", filters.otherSizes);
  if (filters.materials.length) query = query.overlaps("materials", filters.materials);
  if (filters.patterns.length) query = query.overlaps("patterns", filters.patterns);
  if (filters.features.length) query = query.overlaps("features", filters.features);
  if (filters.styles.length) query = query.overlaps("styles", filters.styles);
  if (filters.productTypes.length) query = query.overlaps("product_types", filters.productTypes);
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
  const { data, error } = await query;
  if (error) return c.json({ error: error.message }, 500);
  const rows = data ?? [];
  const hasNext = rows.length > filters.limit;
  const pageRows = rows.slice(0, filters.limit);
  const watched = await watchedProductIds(c.get("db"), c.get("member").userId, pageRows.map((row) => row.id));
  const items = pageRows.map((row) => mapCatalogItem(row, watched.has(row.id)));
  const last = rows[Math.min(rows.length, filters.limit) - 1];
  const body = JSON.stringify({ items, nextCursor: hasNext && last ? encodeCursor({ value: last[sort.column], id: last.id }) : null });
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
  const { data, error } = await c.get("db").rpc(facetFunction, { p_filters: facetFilters });
  if (error) {
    console.error("[catalog/facets]", { code: error.code, message: error.message, details: error.details, hint: error.hint });
    return c.json({ error: error.message }, 500);
  }
  const body = JSON.stringify(data);
  c.executionCtx.waitUntil(edgeCache.put(cacheKey, new Response(body, { headers: { "content-type": "application/json", "cache-control": "max-age=300" } })));
  return new Response(body, { headers: { "content-type": "application/json", "cache-control": "private, max-age=0" } });
});

app.get("/v1/products/:id", async (c) => {
  const id = c.req.param("id");
  const [{ data: product, error }, { data: history }, { data: watch }] = await Promise.all([
    c.get("db").from("catalog_items").select("*").eq("id", id).maybeSingle(),
    c.get("db").from("daily_prices").select("observed_date,min_price,max_price,last_price,source_lpl_30").eq("product_id", id).order("observed_date"),
    c.get("db").from("product_watches").select("product_id").eq("user_id", c.get("member").userId).eq("product_id", id).maybeSingle()
  ]);
  if (error) return c.json({ error: error.message }, 500);
  if (!product) return c.json({ error: "Produktas nerastas" }, 404);
  return c.json({ ...mapCatalogItem(product, Boolean(watch)), history: history ?? [] });
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
    brands: list(query.brands), sources: list(query.sources), categories: list(query.categories), colors: list(query.colors),
    colorShades: list(query.color_shades),
    sizes: list(query.sizes), otherSizes: list(query.other_sizes), materials: list(query.materials),
    patterns: list(query.patterns), features: list(query.features), styles: list(query.styles),
    productTypes: list(query.product_types),
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
    imageUrls: row.image_urls ?? [], colorOriginal: row.color_original, colorFamily: row.color_family, colorShade: row.color_shade ?? "other", categories: row.categories ?? [],
    sizes: row.sizes ?? [], otherSizes: row.other_sizes ?? [], materials: row.materials ?? [], patterns: row.patterns ?? [],
    features: row.features ?? [], styles: row.styles ?? [], productTypes: row.product_types ?? [],
    source: row.source, currentPrice: row.current_price, originalPrice: row.original_price, sourceLpl30: row.source_lpl_30,
    observedMin30d: row.observed_min_30d, currency: row.currency, updatedAt: row.updated_at,
    firstSeenAt: row.first_seen_at, isWatched };
}

async function watchedProductIds(db: SupabaseClient, userId: string, productIds: string[]): Promise<Set<string>> {
  if (!productIds.length) return new Set();
  const { data } = await db.from("product_watches").select("product_id").eq("user_id", userId).in("product_id", productIds);
  return new Set((data ?? []).map((item) => item.product_id));
}

function encodeCursor(value: unknown): string { return btoa(JSON.stringify(value)); }
function decodeCursor(value?: string): { value: string | number; id: string } | null { try { return value ? JSON.parse(atob(value)) : null; } catch { return null; } }
async function sha256(value: string): Promise<string> { const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)); return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join(""); }
function getEdgeCache(): Cache { return (caches as unknown as { default: Cache }).default; }

export default app;
