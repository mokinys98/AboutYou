import { Hono, type MiddlewareHandler } from "hono";
import { cors } from "hono/cors";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { BrandTierSchema, CatalogAlertFiltersSchema, CatalogFiltersSchema, CreateAlertSchema, PRODUCT_DETAIL_PARSER_VERSION, UpdateAlertSchema, isAllowedAboutYouUrl } from "@catalog/shared";
import { z } from "zod";
import { alertFilterFingerprint, canonicalAlertFilters, hasMeaningfulAlertFilters, mapAlertRow, processTelegramAlerts, sendTelegramText } from "./telegram";

type Bindings = {
  ALLOWED_ORIGIN: string;
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  WEB_APP_URL?: string;
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_BOT_USERNAME?: string;
  TELEGRAM_WEBHOOK_SECRET?: string;
};
type SchedulerBindings = Bindings & {
  GITHUB_TOKEN: string;
  GITHUB_OWNER: string;
  GITHUB_REPO: string;
  GITHUB_REF: string;
};
type Variables = { db: SupabaseClient; member: { userId: string; role: "admin" | "viewer"; email: string } };
type SupabaseQueryError = {
  code?: string;
  message: string;
  details?: string | null;
  hint?: string | null;
};

export const EXCLUDED_BASICS_CATEGORIES = [
  "Apatiniai",
  "Apatinės kelnės",
  "Apatiniai marškinėliai",
  "Kojinės",
  "Naktiniai drabužiai",
  "Vonios chalatai"
];

export const EXCLUDED_ACCESSORIES_PATHS = [
  "vyrams>aksesuarai"
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
export function supabaseOrigin(value: string | undefined) {
  try {
    return new URL(value ?? "").origin;
  } catch {
    return null;
  }
}

app.get("/health", (c) => {
  const backendOrigin = supabaseOrigin(c.env.SUPABASE_URL);
  return c.json({ ok: backendOrigin !== null, backendOrigin }, backendOrigin === null ? 503 : 200);
});

const TelegramUpdateSchema = z.object({
  update_id: z.number().int(),
  message: z.object({
    text: z.string().optional(),
    chat: z.object({ id: z.number().int(), type: z.string() }),
    from: z.object({ id: z.number().int(), username: z.string().optional() }).optional()
  }).optional()
});

app.post("/telegram/webhook", async (c) => {
  if (!c.env.TELEGRAM_WEBHOOK_SECRET || c.req.header("X-Telegram-Bot-Api-Secret-Token") !== c.env.TELEGRAM_WEBHOOK_SECRET) {
    return c.json({ error: "Neteisinga Telegram webhook paslaptis" }, 401);
  }
  if (!c.env.SUPABASE_URL || !c.env.SUPABASE_SERVICE_ROLE_KEY || !c.env.TELEGRAM_BOT_TOKEN) {
    return c.json({ error: "Telegram integracija nesukonfigūruota" }, 503);
  }
  const parsed = TelegramUpdateSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "Neteisingas Telegram update" }, 400);
  const db = createClient(c.env.SUPABASE_URL, c.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { error: updateError } = await db.from("telegram_updates").insert({ update_id: parsed.data.update_id });
  if (updateError?.code === "23505") return c.json({ ok: true, duplicate: true });
  if (updateError) return c.json({ error: "Telegram update išsaugoti nepavyko" }, 500);

  const message = parsed.data.message;
  if (!message?.text || message.chat.type !== "private" || !message.from) return c.json({ ok: true });
  const [rawCommand, argument] = message.text.trim().split(/\s+/, 2);
  const command = rawCommand?.split("@", 1)[0];
  try {
    if (command === "/start" && argument) {
      const tokenHash = await sha256(argument);
      const { data: userId, error } = await db.rpc("consume_telegram_link_token", {
        p_token_hash: tokenHash,
        p_telegram_user_id: message.from.id,
        p_chat_id: message.chat.id,
        p_username: message.from.username ?? null
      });
      if (error) throw new Error(error.message);
      await sendTelegramText(message.chat.id, userId
        ? "✅ Telegram sėkmingai prijungtas. Nuo šiol čia gausite katalogo alertus."
        : "Ši prijungimo nuoroda negalioja arba jau buvo panaudota. Sugeneruokite naują profilyje.", c.env);
    } else if (command === "/status") {
      const { data } = await db.from("telegram_connections").select("status").eq("telegram_user_id", message.from.id).maybeSingle();
      await sendTelegramText(message.chat.id, data?.status === "connected" ? "✅ Telegram prijungtas." : "Telegram neprijungtas. Atidarykite profilį kataloge.", c.env);
    } else if (command === "/unlink") {
      const { data: connection, error: lookupError } = await db.from("telegram_connections")
        .select("user_id").eq("telegram_user_id", message.from.id).maybeSingle();
      if (lookupError) throw new Error(lookupError.message);
      if (connection?.user_id) {
        const { error: deleteError } = await db.from("telegram_connections")
          .delete().eq("telegram_user_id", message.from.id);
        if (deleteError) throw new Error(deleteError.message);
        const { error: tokenError } = await db.from("telegram_link_tokens").delete()
          .eq("user_id", connection.user_id).is("used_at", null);
        if (tokenError) throw new Error(tokenError.message);
      }
      await sendTelegramText(message.chat.id, "Telegram atsietas nuo šio projekto. Dabar galite susieti jį su kitu projektu.", c.env);
    } else if (command === "/alerts") {
      const url = `${c.env.WEB_APP_URL?.replace(/\/$/, "") ?? ""}/profile#alerts`;
      await sendTelegramText(message.chat.id, `Alertus galite valdyti profilyje:\n${url}`, c.env);
    } else {
      await sendTelegramText(message.chat.id, "Komandos:\n/status – ryšio būsena\n/unlink – atsieti nuo šio projekto\n/alerts – valdyti alertus\n/help – pagalba", c.env);
    }
  } catch (error) {
    console.error(JSON.stringify({ event: "telegram_webhook_command_failed", updateId: parsed.data.update_id, error: error instanceof Error ? error.message : String(error) }));
  }
  return c.json({ ok: true });
});

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

app.get("/v1/telegram/connection", async (c) => {
  const { data, error } = await c.get("db").from("telegram_connections")
    .select("status,username,linked_at,last_error").eq("user_id", c.get("member").userId).maybeSingle();
  if (error) return c.json({ error: "Telegram būsenos gauti nepavyko" }, 500);
  return c.json({
    connected: data?.status === "connected",
    status: data?.status ?? null,
    username: data?.username ?? null,
    linkedAt: data?.linked_at ?? null,
    lastError: data?.last_error ?? null
  });
});

app.post("/v1/telegram/link", async (c) => {
  if (!c.env.TELEGRAM_BOT_USERNAME || c.env.TELEGRAM_BOT_USERNAME === "your_catalog_bot") return c.json({ error: "Telegram boto vardas nesukonfigūruotas" }, 503);
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const token = btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const expiresAt = new Date(Date.now() + 10 * 60_000).toISOString();
  const db = c.get("db");
  await db.from("telegram_link_tokens").delete().eq("user_id", c.get("member").userId).is("used_at", null);
  const { error } = await db.from("telegram_link_tokens").insert({
    token_hash: await sha256(token), user_id: c.get("member").userId, expires_at: expiresAt
  });
  if (error) return c.json({ error: "Telegram nuorodos sukurti nepavyko" }, 500);
  const botUsername = c.env.TELEGRAM_BOT_USERNAME.replace(/^@/, "");
  return c.json({
    url: `tg://resolve?domain=${encodeURIComponent(botUsername)}&start=${encodeURIComponent(token)}`,
    expiresAt
  });
});

app.delete("/v1/telegram/connection", async (c) => {
  const { error } = await c.get("db").from("telegram_connections").delete().eq("user_id", c.get("member").userId);
  return error ? c.json({ error: "Telegram atjungti nepavyko" }, 500) : c.json({ connected: false });
});

app.post("/v1/telegram/test", async (c) => {
  const { data, error } = await c.get("db").from("telegram_connections")
    .select("chat_id,status").eq("user_id", c.get("member").userId).maybeSingle();
  if (error) return c.json({ error: "Telegram ryšio patikrinti nepavyko" }, 500);
  if (!data || data.status !== "connected") return c.json({ error: "Telegram neprijungtas" }, 409);
  try {
    await sendTelegramText(data.chat_id, "✅ Testinis KAINORAŠČIO pranešimas pristatytas sėkmingai.", c.env);
    return c.json({ sent: true });
  } catch (error) {
    return c.json({ error: error instanceof Error ? error.message : "Testinio pranešimo išsiųsti nepavyko" }, 502);
  }
});

app.get("/v1/alerts", async (c) => {
  const { data, error } = await c.get("db").from("alerts")
    .select("*,products(name,brand,image_urls)").eq("user_id", c.get("member").userId)
    .order("created_at", { ascending: false });
  if (error) return c.json({ error: "Alertų įkelti nepavyko" }, 500);
  return c.json((data ?? []).map(mapAlertRow));
});

app.post("/v1/alerts", async (c) => {
  const input = CreateAlertSchema.safeParse(await c.req.json().catch(() => null));
  if (!input.success) return c.json({ error: input.error.flatten() }, 400);
  const db = c.get("db");
  const userId = c.get("member").userId;
  if (input.data.kind === "filter") {
    const filters = canonicalAlertFilters(input.data.filters);
    if (!hasMeaningfulAlertFilters(filters)) return c.json({ error: "Pasirinkite bent vieną katalogo filtrą" }, 400);
    const { data, error } = await db.from("alerts").insert({
      user_id: userId, kind: "filter", name: input.data.name, filters,
      filter_fingerprint: await alertFilterFingerprint(filters), conditions: { newMatches: true }, state: {}
    }).select("*,products(name,brand,image_urls)").single();
    if (error?.code === "23505") return c.json({ error: "Toks filtro alertas jau egzistuoja" }, 409);
    return error ? c.json({ error: "Filtro alerto sukurti nepavyko" }, 500) : c.json(mapAlertRow(data), 201);
  }

  const { data: existing } = await db.from("alerts").select("id").eq("user_id", userId)
    .eq("product_id", input.data.productId).eq("kind", "product").maybeSingle();
  if (existing) return c.json({ error: "Šios prekės alertas jau egzistuoja" }, 409);
  const { error: watchError } = await db.rpc("set_product_watch", { p_user_id: userId, p_product_id: input.data.productId, p_watched: true });
  if (watchError) return c.json({ error: watchError.message.includes("Product not found") ? "Produktas nerastas" : "Produkto alerto sukurti nepavyko" }, watchError.message.includes("Product not found") ? 404 : 500);
  const { data: state, error: stateError } = await db.rpc("current_product_alert_state", { p_product_id: input.data.productId });
  const { data, error } = stateError ? { data: null, error: stateError } : await db.from("alerts").update({
    name: input.data.name, conditions: input.data.conditions, state, last_evaluated_at: new Date().toISOString(), updated_at: new Date().toISOString()
  }).eq("user_id", userId).eq("product_id", input.data.productId).select("*,products(name,brand,image_urls)").single();
  if (error) {
    await db.rpc("set_product_watch", { p_user_id: userId, p_product_id: input.data.productId, p_watched: false });
    return c.json({ error: "Produkto alerto sukurti nepavyko" }, 500);
  }
  return c.json(mapAlertRow(data), 201);
});

app.patch("/v1/alerts/:id", async (c) => {
  const id = z.string().uuid().safeParse(c.req.param("id"));
  const input = UpdateAlertSchema.safeParse(await c.req.json().catch(() => null));
  if (!id.success || !input.success) return c.json({ error: "Neteisingi alerto pakeitimai" }, 400);
  const db = c.get("db");
  const userId = c.get("member").userId;
  const { data: alert, error: lookupError } = await db.from("alerts").select("id,kind,product_id,enabled")
    .eq("id", id.data).eq("user_id", userId).maybeSingle();
  if (lookupError) return c.json({ error: "Alerto patikrinti nepavyko" }, 500);
  if (!alert) return c.json({ error: "Alertas nerastas" }, 404);
  if (alert.kind === "filter" && input.data.conditions && !("newMatches" in input.data.conditions)) return c.json({ error: "Neteisingos filtro alerto sąlygos" }, 400);
  if (alert.kind === "product" && input.data.filters) return c.json({ error: "Produkto alertas neturi katalogo filtrų" }, 400);

  const changes: Record<string, unknown> = { updated_at: new Date().toISOString() };
  if (input.data.name !== undefined) changes.name = input.data.name;
  if (input.data.enabled !== undefined) changes.enabled = input.data.enabled;
  if (input.data.conditions !== undefined) changes.conditions = input.data.conditions;
  if (alert.kind === "filter" && input.data.filters) {
    const filters = canonicalAlertFilters(CatalogAlertFiltersSchema.parse(input.data.filters));
    if (!hasMeaningfulAlertFilters(filters)) return c.json({ error: "Pasirinkite bent vieną katalogo filtrą" }, 400);
    changes.filters = filters;
    changes.filter_fingerprint = await alertFilterFingerprint(filters);
    changes.state = {};
    changes.last_evaluated_at = new Date().toISOString();
  }
  if (alert.kind === "product" && input.data.conditions) {
    const { data: state, error } = await db.rpc("current_product_alert_state", { p_product_id: alert.product_id });
    if (error || !state) return c.json({ error: "Produkto būsenos gauti nepavyko" }, 500);
    changes.state = state;
    changes.last_evaluated_at = new Date().toISOString();
  }
  if (input.data.enabled === true && !alert.enabled) {
    changes.last_evaluated_at = new Date().toISOString();
    if (alert.kind === "filter") changes.state = {};
    else {
      const { data: state, error } = await db.rpc("current_product_alert_state", { p_product_id: alert.product_id });
      if (error || !state) return c.json({ error: "Produkto būsenos gauti nepavyko" }, 500);
      changes.state = state;
    }
  }
  const { data, error } = await db.from("alerts").update(changes).eq("id", id.data).eq("user_id", userId)
    .select("*,products(name,brand,image_urls)").single();
  if (error?.code === "23505") return c.json({ error: "Toks filtro alertas jau egzistuoja" }, 409);
  return error ? c.json({ error: "Alerto atnaujinti nepavyko" }, 500) : c.json(mapAlertRow(data));
});

app.delete("/v1/alerts/:id", async (c) => {
  const id = z.string().uuid().safeParse(c.req.param("id"));
  if (!id.success) return c.json({ error: "Neteisingas alerto ID" }, 400);
  const db = c.get("db"); const userId = c.get("member").userId;
  const { data: alert } = await db.from("alerts").select("kind,product_id").eq("id", id.data).eq("user_id", userId).maybeSingle();
  if (!alert) return c.json({ error: "Alertas nerastas" }, 404);
  if (alert.kind === "product") {
    const { error } = await db.rpc("set_product_watch", { p_user_id: userId, p_product_id: alert.product_id, p_watched: false });
    return error ? c.json({ error: "Produkto alerto ištrinti nepavyko" }, 500) : c.json({ deleted: true });
  }
  const { error } = await db.from("alerts").delete().eq("id", id.data).eq("user_id", userId);
  return error ? c.json({ error: "Alerto ištrinti nepavyko" }, 500) : c.json({ deleted: true });
});

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

  let query = c.get("db").from("catalog_items_read_with_lpl").select("*", filters.cursor ? undefined : { count: "exact" });
  if (filters.lplProximityPct !== undefined) {
    query = query.lte("lpl_price_ratio", 100 + filters.lplProximityPct);
  }
  if (filters.brands.length) query = query.in("brand", filters.brands);
  if (filters.brandTiers.length) query = query.in("brand_tier", filters.brandTiers);
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
  if (filters.excludeAccessories) {
    query = query.not("category_paths", "ov", postgresArrayLiteral(EXCLUDED_ACCESSORIES_PATHS));
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
  query = query.order(sort.column, { ascending: sort.ascending, nullsFirst: false }).order("id", { ascending: sort.ascending }).limit(filters.limit + 1);
  if (cursor) {
    query = query.or(catalogCursorFilter(sort, cursor));
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
  const effectiveFacetFilters = {
    ...facetFilters,
    categories: facetFilters.categoryPath ? [facetFilters.categoryPath] : facetFilters.categories
  };
  const { data, error } = await c.get("db").rpc("catalog_facets_cached", { p_filters: effectiveFacetFilters });
  if (error) {
    console.error("[catalog/facets]", { code: error.code, message: error.message, details: error.details, hint: error.hint });
    return c.json({ error: error.message }, 500);
  }
  const body = JSON.stringify(data ?? {});
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
    { data: artifact, error: artifactError }
  ] = await Promise.all([
    c.get("db").from("catalog_items").select("*").eq("id", id.data).maybeSingle(),
    c.get("db").from("product_detail_sync").select("status,parser_version,static_synced_at,availability_synced_at").eq("product_id", id.data).maybeSingle(),
    c.get("db").from("product_detail_sections").select("section_key,source_label,status,items,position").eq("product_id", id.data).order("position"),
    c.get("db").from("product_color_options").select("external_id,label,url,selected,position").eq("product_id", id.data).order("position"),
    c.get("db").from("product_size_options").select("external_id,label,size_group,selected,selectable,availability,position").eq("product_id", id.data).order("position"),
    c.get("db").from("product_sync_artifacts")
      .select("storage_path,payload_hash,created_at,source_endpoint,parser_version")
      .eq("product_id", id.data).eq("upload_status", "ready")
      .in("artifact_kind", ["success_sample", "blocked_schema"])
      .order("created_at", { ascending: false }).limit(1).maybeSingle()
  ]);
  const queryError = error ?? detailSyncError ?? detailSectionsError ?? colorOptionsError ?? sizeOptionsError ?? artifactError;
  if (queryError) return c.json({ error: queryError.message }, 500);
  if (!product) return c.json({ error: "Produktas nerastas" }, 404);
  const raw = artifact ? await downloadRawArtifact(c.get("db"), artifact) : null;
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
  const { data, error } = await c.get("db").rpc("set_product_watch", {
    p_user_id: c.get("member").userId, p_product_id: productId.data, p_watched: true
  });
  if (error?.message.includes("Product not found")) return c.json({ error: "Produktas nerastas" }, 404);
  return error ? c.json({ error: error.message }, 500) : c.json(data);
});

app.delete("/v1/watchlist/:productId", async (c) => {
  const productId = z.string().uuid().safeParse(c.req.param("productId"));
  if (!productId.success) return c.json({ error: "Neteisingas produkto ID" }, 400);
  const { data, error } = await c.get("db").rpc("set_product_watch", {
    p_user_id: c.get("member").userId, p_product_id: productId.data, p_watched: false
  });
  return error ? c.json({ error: error.message }, 500) : c.json(data);
});

const BrandTierInput = z.object({
  displayName: z.string().trim().min(1).max(120),
  tier: BrandTierSchema
});

export function normalizeBrandKey(value: string): string {
  return value.trim().replace(/\s+/g, " ").toLocaleLowerCase("lt");
}

app.get("/v1/admin/brand-tiers", requireAdmin, async (c) => {
  const { data, error } = await c.get("db").from("brand_tier_admin_items").select("*")
    .order("active_products", { ascending: false }).order("display_name");
  if (error) return c.json({ error: error.message }, 500);
  return c.json((data ?? []).map((row) => ({
    brandKey: row.brand_key,
    displayName: row.display_name,
    activeProducts: Number(row.active_products ?? 0),
    tier: row.tier ?? null,
    updatedAt: row.updated_at ?? null
  })));
});

app.put("/v1/admin/brand-tiers/:brandKey", requireAdmin, async (c) => {
  const brandKey = normalizeBrandKey(c.req.param("brandKey"));
  const input = BrandTierInput.safeParse(await c.req.json().catch(() => null));
  if (!input.success || normalizeBrandKey(input.data.displayName) !== brandKey) {
    return c.json({ error: "Neteisingi brando tier duomenys" }, 400);
  }
  const { data, error } = await c.get("db").from("brand_tiers").upsert({
    brand_key: brandKey,
    display_name: input.data.displayName,
    tier: input.data.tier,
    updated_at: new Date().toISOString(),
    updated_by: c.get("member").userId
  }, { onConflict: "brand_key" }).select("brand_key,display_name,tier,updated_at").single();
  if (error) return c.json({ error: error.message }, 500);
  c.executionCtx.waitUntil((async () => {
    const { data: requestedVersion, error: refreshError } = await c.get("db").rpc("request_catalog_items_read_refresh");
    if (refreshError) {
      console.error(JSON.stringify({ event: "catalog_read_model_refresh_request_failed", error: refreshError.message }));
    } else {
      console.log(JSON.stringify({ event: "catalog_read_model_refresh_requested", requestedVersion }));
    }
  })());
  return c.json({ brandKey: data.brand_key, displayName: data.display_name, tier: data.tier, updatedAt: data.updated_at });
});

app.delete("/v1/admin/brand-tiers/:brandKey", requireAdmin, async (c) => {
  const brandKey = normalizeBrandKey(c.req.param("brandKey"));
  const { error } = await c.get("db").from("brand_tiers").delete().eq("brand_key", brandKey);
  if (error) return c.json({ error: error.message }, 500);
  c.executionCtx.waitUntil((async () => {
    const { data: requestedVersion, error: refreshError } = await c.get("db").rpc("request_catalog_items_read_refresh");
    if (refreshError) {
      console.error(JSON.stringify({ event: "catalog_read_model_refresh_request_failed", error: refreshError.message }));
    } else {
      console.log(JSON.stringify({ event: "catalog_read_model_refresh_requested", requestedVersion }));
    }
  })());
  return c.json({ deleted: true });
});

app.get("/v1/sync-targets", requireAdmin, async (c) => {
  const { data, error } = await c.get("db").from("sync_targets").select("*,sources(slug,name)").order("priority");
  return error ? c.json({ error: error.message }, 500) : c.json(data);
});

app.get("/v1/admin/dashboard", requireAdmin, async (c) => {
  try {
    return c.json(await loadAdminDashboard(c.get("db")));
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : "Dashboard statistikos uzkrauti nepavyko";
    return c.json({ error: message }, 500);
  }
});

export async function loadAdminDashboard(db: Pick<SupabaseClient, "from" | "rpc">, now = new Date()) {
  const [
    totalProducts,
    activeProducts,
    catalogProducts,
    metadataProducts,
    premiumProducts,
    newProducts,
    belowObservedProducts,
    exactCategoryProducts,
    fallbackCategoryProducts,
    uncategorizedProducts,
    legacyCategories,
    facets,
    metadataSummary,
    enabledTargets,
    disabledTargets,
    latestRuns
  ] = await Promise.all([
    counted("dashboard.products.total", db.from("products").select("id", { count: "exact", head: true })),
    counted("dashboard.products.active", db.from("products").select("id", { count: "exact", head: true }).eq("active", true)),
    counted("dashboard.catalog.total", db.from("catalog_items_read").select("id", { count: "exact", head: true })),
    counted("dashboard.products.metadata_complete", db.from("products").select("id", { count: "exact", head: true }).eq("active", true).not("metadata_updated_at", "is", null)),
    counted("dashboard.catalog.premium", db.from("catalog_items_read").select("id", { count: "exact", head: true }).eq("is_premium", true)),
    counted("dashboard.catalog.new_30d", db.from("catalog_items_read").select("id", { count: "exact", head: true }).gte("first_seen_at", newestCatalogCutoff(now))),
    counted("dashboard.catalog.below_observed_30d", db.from("catalog_items_read").select("id", { count: "exact", head: true }).eq("below_observed_30d", true)),
    counted("dashboard.categories.exact_products", db.from("products").select("id", { count: "exact", head: true }).eq("active", true).not("category_path_updated_at", "is", null)),
    counted("dashboard.categories.fallback_products", db.from("products").select("id", { count: "exact", head: true }).eq("active", true).is("category_path_updated_at", null)),
    counted("dashboard.catalog.uncategorized", db.from("catalog_items_read").select("id", { count: "exact", head: true }).eq("category_paths", "{}")),
    counted("dashboard.categories.legacy", db.from("categories").select("id", { count: "exact", head: true }).is("path", null)),
    db.rpc("catalog_facets_cached", { p_filters: {} }),
    db.rpc("product_detail_sync_summary", { p_parser_version: PRODUCT_DETAIL_PARSER_VERSION }),
    counted("dashboard.sync_targets.enabled", db.from("sync_targets").select("id", { count: "exact", head: true }).eq("enabled", true)),
    counted("dashboard.sync_targets.disabled", db.from("sync_targets").select("id", { count: "exact", head: true }).eq("enabled", false)),
    db.from("sync_runs").select("id,status,started_at,finished_at,products_count,error,sync_targets(label)").order("started_at", { ascending: false }).limit(8)
  ]);

  const queryError = facets.error ?? metadataSummary.error ?? latestRuns.error;
  if (queryError) throw new Error(queryError.message);

  return {
    generatedAt: now.toISOString(),
    parserVersion: PRODUCT_DETAIL_PARSER_VERSION,
    totals: {
      products: totalProducts,
      activeProducts,
      catalogProducts,
      metadataProducts,
      premiumProducts,
      newProducts,
      belowObservedProducts,
      exactCategoryProducts,
      fallbackCategoryProducts,
      uncategorizedProducts,
      legacyCategories,
      enabledTargets,
      disabledTargets
    },
    metadata: metadataSummary.data ?? {},
    categories: dashboardCategories(facets.data),
    latestRuns: latestRuns.data ?? []
  };
}

export function dashboardCategories(payload: unknown): Array<Record<string, unknown>> {
  if (!payload || typeof payload !== "object" || !("categories" in payload)) return [];
  const categories = (payload as { categories?: unknown }).categories;
  return Array.isArray(categories) ? categories : [];
}

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
  // Hono normally gives us decoded query values, but parseFilters is also used
  // with encoded values in tests and internal callers. Preserve literal `%`
  // characters while decoding any valid percent-encoded bytes.
  const decodeFilterValue = (value: string) => {
    try {
      return decodeURIComponent(value.replace(/%(?![\dA-Fa-f]{2})/g, "%25"));
    } catch {
      return value;
    }
  };
  const list = (value?: string) => value ? value.split(",").map(decodeFilterValue).filter(Boolean) : [];
  return CatalogFiltersSchema.safeParse({
    brands: list(query.brands), brandTiers: list(query.brand_tiers), sources: list(query.sources), categories: list(query.categories), categoryPath: query.category ? decodeFilterValue(query.category) : undefined, colors: list(query.colors),
    colorShades: list(query.color_shades),
    sizes: list(query.sizes), otherSizes: list(query.other_sizes), materials: list(query.materials),
    patterns: list(query.patterns), features: list(query.features), styles: list(query.styles),
    productTypes: list(query.product_types),
    isPremium: query.premium === "true",
    excludeBasics: query.exclude_basics === "true",
    excludeAccessories: query.exclude_accessories === "true",
    priceMin: query.price_min ? Number(query.price_min) : undefined, priceMax: query.price_max ? Number(query.price_max) : undefined,
    discountMin: query.discount_min ? Number(query.discount_min) : undefined, lplProximityPct: query.lpl_proximity_pct !== undefined && query.lpl_proximity_pct !== "" ? Number(query.lpl_proximity_pct) : undefined, belowObserved30d: query.below_observed_30d === "true",
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

export function sortDefinition(sort: string) {
  if (sort === "price_asc") return { column: "current_price", ascending: true } as const;
  if (sort === "price_desc") return { column: "current_price", ascending: false } as const;
  if (sort === "source_lpl_asc") return { column: "source_lpl_30", ascending: true, nullable: true } as const;
  if (sort === "source_lpl_desc") return { column: "source_lpl_30", ascending: false, nullable: true } as const;
  if (sort === "discount_desc") return { column: "discount_pct", ascending: false } as const;
  if (sort === "first_seen") return { column: "first_seen_at", ascending: false } as const;
  return { column: "updated_at", ascending: false } as const;
}

type CatalogSortDefinition = ReturnType<typeof sortDefinition>;
type CatalogCursor = { value: string | number | null; id: string };

export function catalogCursorFilter(sort: CatalogSortDefinition, cursor: CatalogCursor): string {
  const operator = sort.ascending ? "gt" : "lt";
  if ("nullable" in sort && sort.nullable) {
    if (cursor.value === null) return `and(${sort.column}.is.null,id.${operator}.${cursor.id})`;
    return `${sort.column}.${operator}.${cursor.value},and(${sort.column}.eq.${cursor.value},id.${operator}.${cursor.id}),${sort.column}.is.null`;
  }
  return `${sort.column}.${operator}.${cursor.value},and(${sort.column}.eq.${cursor.value},id.${operator}.${cursor.id})`;
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
    features: row.features ?? [], styles: row.styles ?? [], productTypes: row.product_types ?? [], isPremium: row.is_premium ?? false, brandTier: row.brand_tier ?? null,
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
    rawAvailable: Boolean(raw),
    raw: raw ? {
      payload: raw.payload,
      payloadHash: raw.payload_hash,
      fetchedAt: raw.fetched_at,
      sourceEndpoint: raw.source_endpoint,
      parserVersion: raw.parser_version
    } : null
  };
}

export async function downloadRawArtifact(db: SupabaseClient, artifact: Record<string, any>): Promise<Record<string, any> | null> {
  if (!artifact.storage_path) return null;
  try {
    const { data, error } = await db.storage.from("sync-raw").download(artifact.storage_path);
    if (error) throw error;
    const decompressed = data.stream().pipeThrough(new DecompressionStream("gzip"));
    const payload = JSON.parse(await new Response(decompressed).text()) as Record<string, unknown>;
    return {
      payload,
      payload_hash: artifact.payload_hash,
      fetched_at: artifact.created_at,
      source_endpoint: artifact.source_endpoint,
      parser_version: artifact.parser_version
    };
  } catch (error) {
    console.error("[product/debug/raw]", { path: artifact.storage_path, error: error instanceof Error ? error.message : String(error) });
    return null;
  }
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

export async function counted(operation: string, query: PromiseLike<{ count: number | null; error: SupabaseQueryError | null }>): Promise<number> {
  const startedAt = performance.now();
  const { count, error } = await query;
  if (error) {
    const normalizedMessage = error.message.toLowerCase();
    console.error(JSON.stringify({
      event: "supabase_query_failed",
      operation,
      durationMs: Math.round((performance.now() - startedAt) * 100) / 100,
      code: error.code ?? null,
      message: error.message,
      details: error.details ?? null,
      hint: error.hint ?? null,
      timedOut: error.code === "57014" || normalizedMessage.includes("statement timeout") || normalizedMessage.includes("canceling statement")
    }));
    throw new Error(error.message);
  }
  return count ?? 0;
}

function encodeCursor(value: unknown): string { return btoa(JSON.stringify(value)); }
function decodeCursor(value?: string): { value: string | number | null; id: string } | null { try { return value ? JSON.parse(atob(value)) : null; } catch { return null; } }
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
    if (controller.cron === "*/5 * * * *") {
      if (!env.TELEGRAM_BOT_TOKEN || !env.TELEGRAM_WEBHOOK_SECRET || !env.TELEGRAM_BOT_USERNAME || env.TELEGRAM_BOT_USERNAME === "your_catalog_bot") {
        console.warn(JSON.stringify({ event: "telegram_alerts_skipped", reason: "Telegram integracija nesukonfigūruota" }));
        return;
      }
      const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
      try {
        const result = await processTelegramAlerts(db, env);
        console.log(JSON.stringify({ event: "telegram_alerts_processed", ...result }));
      } catch (error) {
        console.error(JSON.stringify({ event: "telegram_alerts_failed", error: error instanceof Error ? error.message : String(error) }));
        throw error;
      }
      return;
    }
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
