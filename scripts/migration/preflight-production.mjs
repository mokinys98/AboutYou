const config = {
  phase: process.env.MIGRATION_PHASE ?? "rehearsal",
  previewUrl: process.env.MIGRATION_PREVIEW_URL ?? "https://staging-preview.aboutyou-private-catalog-web.pages.dev",
  productionUrl: process.env.MIGRATION_PRODUCTION_URL ?? "https://aboutyou-private-catalog-web.pages.dev",
  stagingApiUrl: process.env.MIGRATION_STAGING_API_URL ?? "https://aboutyou-private-catalog-api-staging.aurimas-zvirb.workers.dev",
  productionApiUrl: process.env.MIGRATION_PRODUCTION_API_URL ?? "https://aboutyou-private-catalog-api.aurimas-zvirb.workers.dev",
  stagingSupabaseUrl: process.env.MIGRATION_STAGING_SUPABASE_URL ?? "https://supabase-staging.rinkissaupigiausia.online"
};

if (!new Set(["rehearsal", "cutover"]).has(config.phase)) {
  console.error("MIGRATION_PHASE must be rehearsal or cutover");
  process.exit(2);
}

const results = [];

function record(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` - ${detail}` : ""}`);
}

async function request(url, options = {}) {
  return fetch(url, {
    redirect: "follow",
    signal: AbortSignal.timeout(15_000),
    ...options
  });
}

function runtimeConfig(html) {
  const supabaseUrl = html.match(/supabaseUrl:"([^"]+)"/)?.[1];
  const apiBase = html.match(/apiBase:"([^"]+)"/)?.[1];
  const anonKeyPresent = /supabaseAnonKey:"[^"]+"/.test(html);
  return { supabaseUrl, apiBase, anonKeyPresent };
}

async function pageConfig(name, url) {
  try {
    const response = await request(`${url}/`);
    const html = await response.text();
    const runtime = runtimeConfig(html);
    record(`${name} page`, response.ok, `HTTP ${response.status}`);
    record(`${name} public config present`, Boolean(runtime.supabaseUrl && runtime.apiBase && runtime.anonKeyPresent),
      `Supabase=${runtime.supabaseUrl ?? "missing"}, API=${runtime.apiBase ?? "missing"}, anon=${runtime.anonKeyPresent ? "present" : "missing"}`);
    return runtime;
  } catch (error) {
    record(`${name} page`, false, error instanceof Error ? error.message : String(error));
    return {};
  }
}

async function health(name, baseUrl) {
  try {
    const response = await request(`${baseUrl}/health`);
    const body = await response.json().catch(() => null);
    record(`${name} health`, response.status === 200 && body?.ok === true, `HTTP ${response.status}`);
  } catch (error) {
    record(`${name} health`, false, error instanceof Error ? error.message : String(error));
  }
}

async function unauthenticatedCatalog(name, baseUrl) {
  try {
    const response = await request(`${baseUrl}/v1/catalog`);
    record(`${name} unauthenticated catalog gate`, response.status === 401, `HTTP ${response.status}`);
  } catch (error) {
    record(`${name} unauthenticated catalog gate`, false, error instanceof Error ? error.message : String(error));
  }
}

async function cors(name, apiUrl, origin) {
  try {
    const response = await request(`${apiUrl}/v1/catalog`, {
      method: "OPTIONS",
      headers: {
        Origin: origin,
        "Access-Control-Request-Method": "GET",
        "Access-Control-Request-Headers": "Authorization,Content-Type"
      }
    });
    const allowedOrigin = response.headers.get("access-control-allow-origin");
    record(`${name} CORS`, response.status === 204 && allowedOrigin === origin,
      `HTTP ${response.status}, allow-origin=${allowedOrigin ?? "missing"}`);
  } catch (error) {
    record(`${name} CORS`, false, error instanceof Error ? error.message : String(error));
  }
}

async function jwks(name, supabaseUrl) {
  if (!supabaseUrl) {
    record(`${name} JWKS`, false, "Supabase URL missing");
    return;
  }
  try {
    const response = await request(`${supabaseUrl}/auth/v1/.well-known/jwks.json`);
    const body = await response.json().catch(() => null);
    record(`${name} JWKS`, response.status === 200 && Array.isArray(body?.keys) && body.keys.length > 0,
      `HTTP ${response.status}, keys=${Array.isArray(body?.keys) ? body.keys.length : 0}`);
  } catch (error) {
    record(`${name} JWKS`, false, error instanceof Error ? error.message : String(error));
  }
}

console.log(`Migration preflight phase: ${config.phase}`);

const [preview, production] = await Promise.all([
  pageConfig("Preview", config.previewUrl),
  pageConfig("Production", config.productionUrl)
]);

record("Preview uses VPS Supabase", preview.supabaseUrl === config.stagingSupabaseUrl,
  `actual=${preview.supabaseUrl ?? "missing"}`);
record("Preview uses staging API", preview.apiBase === config.stagingApiUrl,
  `actual=${preview.apiBase ?? "missing"}`);
record("Production uses production API", production.apiBase === config.productionApiUrl,
  `actual=${production.apiBase ?? "missing"}`);

if (config.phase === "rehearsal") {
  record("Production remains on source Supabase", Boolean(production.supabaseUrl) && production.supabaseUrl !== config.stagingSupabaseUrl,
    `actual=${production.supabaseUrl ?? "missing"}`);
} else {
  record("Production uses VPS Supabase", production.supabaseUrl === config.stagingSupabaseUrl,
    `actual=${production.supabaseUrl ?? "missing"}`);
}

await Promise.all([
  health("Staging API", config.stagingApiUrl),
  health("Production API", config.productionApiUrl),
  unauthenticatedCatalog("Staging API", config.stagingApiUrl),
  unauthenticatedCatalog("Production API", config.productionApiUrl),
  cors("Preview to staging API", config.stagingApiUrl, config.previewUrl),
  cors("Production to production API", config.productionApiUrl, config.productionUrl),
  jwks("VPS Supabase", config.stagingSupabaseUrl),
  jwks("Production Supabase", production.supabaseUrl)
]);

const failed = results.filter((result) => !result.ok);
console.log(`\nSummary: ${results.length - failed.length}/${results.length} checks passed`);
if (failed.length > 0) {
  console.error(`Failed checks: ${failed.map((result) => result.name).join(", ")}`);
  process.exit(1);
}

