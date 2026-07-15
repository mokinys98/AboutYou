import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { EXCLUDED_BASICS_CATEGORIES, allowedCorsOrigin, app, catalogCacheUrl, catalogCursorFilter, counted, dispatchGitHubWorkflow, downloadRawArtifact, inspectProductDebugPayload, inviteErrorResponse, loadAdminDashboard, mapProductDebug, mapProductDetail, newestCatalogCutoff, normalizeBrandKey, parseFilters, postgresArrayLiteral, priceComparisonColumn, sortDefinition, teamMemberStatus, workflowForCron } from "./index";

describe("catalog API", () => {
  it("exposes an unauthenticated health check", async () => {
    const response = await app.request("/health", {}, {
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
      ALLOWED_ORIGIN: "http://localhost:3000"
    });
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ ok: true });
  });

  it("rejects Telegram webhooks without the configured secret", async () => {
    const response = await app.request("/telegram/webhook", { method: "POST", body: "{}", headers: { "content-type": "application/json" } }, {
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
      ALLOWED_ORIGIN: "http://localhost:3000",
      TELEGRAM_WEBHOOK_SECRET: "expected-secret",
      TELEGRAM_BOT_TOKEN: "test-token"
    });
    expect(response.status).toBe(401);
  });

  it("protects catalog routes", async () => {
    const response = await app.request("/v1/catalog", {}, {
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
      ALLOWED_ORIGIN: "http://localhost:3000"
    });
    expect(response.status).toBe(401);
  });

  it("allows the deployed web origin and local Nuxt dev origins for CORS", async () => {
    const allowedOrigin = "https://aboutyou-private-catalog-web.pages.dev";
    expect(allowedCorsOrigin("https://aboutyou-private-catalog-web.pages.dev", allowedOrigin)).toBe("https://aboutyou-private-catalog-web.pages.dev");
    expect(allowedCorsOrigin("http://localhost:3002", allowedOrigin)).toBe("http://localhost:3002");
    expect(allowedCorsOrigin("https://example.com", allowedOrigin)).toBeNull();

    const response = await app.request("/v1/catalog", {
      method: "OPTIONS",
      headers: {
        Origin: "http://localhost:3002",
        "Access-Control-Request-Method": "GET",
        "Access-Control-Request-Headers": "authorization,content-type"
      }
    }, {
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
      ALLOWED_ORIGIN: allowedOrigin
    });

    expect(response.status).toBe(204);
    expect(response.headers.get("access-control-allow-origin")).toBe("http://localhost:3002");
  });

  it("reports missing authentication configuration separately from an invalid session", async () => {
    const response = await app.request("/v1/catalog", {
      headers: { Authorization: "Bearer test-token" }
    }, {
      SUPABASE_URL: "",
      SUPABASE_SERVICE_ROLE_KEY: "",
      ALLOWED_ORIGIN: "http://localhost:3000"
    });
    expect(response.status).toBe(503);
    await expect(response.json()).resolves.toEqual({ error: "API autentifikacija nesukonfigūruota" });
  });

  it("maps team member invitation states without exposing auth internals", () => {
    expect(teamMemberStatus({ active: false, accepted_at: null })).toBe("disabled");
    expect(teamMemberStatus({ active: true, accepted_at: null })).toBe("pending");
    expect(teamMemberStatus({ active: true, accepted_at: "2026-07-11T10:00:00Z" })).toBe("active");
  });

  it("returns safe actionable invitation errors", () => {
    expect(inviteErrorResponse({ message: "rate limit exceeded", status: 429 })).toMatchObject({ status: 429 });
    expect(inviteErrorResponse({ message: "User already registered", status: 422 })).toMatchObject({ status: 409 });
    expect(inviteErrorResponse({ message: "SMTP delivery failed", status: 500 })).toMatchObject({ status: 502 });
    expect(inviteErrorResponse({ message: "unexpected provider response", status: 400 })).toMatchObject({
      status: 400,
      message: "Kvietimo išsiųsti nepavyko."
    });
  });

  it("parses detailed colors, premium, basics exclusion and the source LPL comparison", () => {
    const parsed = parseFilters({ color_shades: "teal,olive", brand_tiers: "S,A", premium: "true", exclude_basics: "true", exclude_accessories: "true", below_observed_30d: "true", price_comparison: "source_lpl" });
    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data.colorShades).toEqual(["teal", "olive"]);
      expect(parsed.data.brandTiers).toEqual(["S", "A"]);
      expect(parsed.data.isPremium).toBe(true);
      expect(parsed.data.excludeBasics).toBe(true);
      expect(parsed.data.excludeAccessories).toBe(true);
      expect(parsed.data.priceComparison).toBe("source_lpl");
      expect(parsed.data.belowObserved30d).toBe(true);
    }
    expect(priceComparisonColumn("source_lpl")).toBe("below_source_lpl_30d");
    expect(priceComparisonColumn("observed")).toBe("below_observed_30d");
    expect(postgresArrayLiteral(EXCLUDED_BASICS_CATEGORIES)).toContain('"Kojinės"');
  });

  it("normalizes brand keys without collapsing distinct subbrands", () => {
    expect(normalizeBrandKey("  Polo   Ralph Lauren ")).toBe("polo ralph lauren");
    expect(normalizeBrandKey("Calvin Klein Jeans")).not.toBe(normalizeBrandKey("Calvin Klein"));
    expect(parseFilters({ brand_tiers: "S,X" }).success).toBe(false);
  });

  it("parses a stable category path separately from legacy category names", () => {
    const parsed = parseFilters({ category: "vyrams%3Edrabu%C5%BEiai", categories: "Marškiniai" });
    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data.categoryPath).toBe("vyrams>drabužiai");
      expect(parsed.data.categories).toEqual(["Marškiniai"]);
    }
  });

  it("parses decoded material names containing a literal percent sign", () => {
    const decoded = parseFilters({ materials: "100% Medvilnė" });
    const encoded = parseFilters({ materials: "100%25%20Medviln%C4%97" });
    const malformed = parseFilters({ materials: "%E0%A4%A" });

    expect(decoded.success && decoded.data.materials).toEqual(["100% Medvilnė"]);
    expect(encoded.success && encoded.data.materials).toEqual(["100% Medvilnė"]);
    expect(malformed.success && malformed.data.materials).toEqual(["%E0%A4%A"]);
  });

  it("isolates personalized catalog cache entries by user", () => {
    const first = catalogCacheUrl("https://api.example/v1/catalog?sort=newest", "user-a").toString();
    const second = catalogCacheUrl("https://api.example/v1/catalog?sort=newest", "user-b").toString();
    expect(first).not.toBe(second);
    expect(first).toContain("watchlist_user=user-a");
  });

  it("parses the news filter and uses a stable 30-day cutoff", () => {
    const parsed = parseFilters({ new_only: "true" });
    expect(parsed.success && parsed.data.newOnly).toBe(true);
    expect(newestCatalogCutoff(new Date("2026-07-06T12:00:00.000Z"))).toBe("2026-06-06T12:00:00.000Z");
  });

  it("loads admin dashboard catalog statistics from the read model and cached facets", async () => {
    const category = { id: "category-1", parentId: null, name: "Drabužiai", level: 2, path: "vyrams>drabuziai", count: 7 };
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof Request ? input.url : String(input);
      if (url.includes("/rest/v1/rpc/catalog_facets_cached")) {
        return Response.json({ categories: [category] });
      }
      if (url.includes("/rest/v1/rpc/product_detail_sync_summary")) {
        return Response.json({ active: 1, complete: 1 });
      }
      if (url.includes("/rest/v1/sync_runs")) return Response.json([]);
      return new Response(null, { status: 200, headers: { "content-range": "0-0/1" } });
    });
    vi.stubGlobal("fetch", fetchMock);
    const db = createClient("https://example.supabase.co", "test-service-role-key", { auth: { persistSession: false } });

    try {
      const dashboard = await loadAdminDashboard(db, new Date("2026-07-15T12:00:00.000Z"));
      const urls = fetchMock.mock.calls.map(([input]) => input instanceof Request ? input.url : String(input));

      expect(urls.some((url) => url.includes("/rest/v1/catalog_items_read?"))).toBe(true);
      expect(urls.some((url) => /\/rest\/v1\/catalog_items(?:\?|$)/.test(url))).toBe(false);
      expect(urls.some((url) => url.includes("/rest/v1/rpc/catalog_facets_cached"))).toBe(true);
      expect(urls.some((url) => url.includes("/rest/v1/rpc/catalog_category_facets"))).toBe(false);
      expect(dashboard.categories).toEqual([category]);
      expect(dashboard.generatedAt).toBe("2026-07-15T12:00:00.000Z");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("logs a named structured Supabase timeout from counted queries", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const query = Promise.resolve({
      count: null,
      error: { code: "57014", message: "canceling statement due to statement timeout", details: "query exceeded limit", hint: "use the read model" }
    });

    await expect(counted("dashboard.catalog.total", query)).rejects.toThrow("statement timeout");
    expect(consoleError).toHaveBeenCalledOnce();
    const log = JSON.parse(String(consoleError.mock.calls[0]?.[0]));
    expect(log).toMatchObject({
      event: "supabase_query_failed",
      operation: "dashboard.catalog.total",
      code: "57014",
      message: "canceling statement due to statement timeout",
      details: "query exceeded limit",
      hint: "use the read model",
      timedOut: true,
      durationMs: expect.any(Number)
    });
    consoleError.mockRestore();
  });

  it("supports source LPL sorting with null values placed after known prices", () => {
    const ascending = parseFilters({ sort: "source_lpl_asc" });
    const descending = parseFilters({ sort: "source_lpl_desc" });
    expect(ascending.success && ascending.data.sort).toBe("source_lpl_asc");
    expect(descending.success && descending.data.sort).toBe("source_lpl_desc");
    expect(sortDefinition("source_lpl_asc")).toMatchObject({ column: "source_lpl_30", ascending: true, nullable: true });
    expect(sortDefinition("source_lpl_desc")).toMatchObject({ column: "source_lpl_30", ascending: false, nullable: true });
    expect(catalogCursorFilter(sortDefinition("source_lpl_asc"), { value: 1999, id: "product-a" }))
      .toBe("source_lpl_30.gt.1999,and(source_lpl_30.eq.1999,id.gt.product-a),source_lpl_30.is.null");
    expect(catalogCursorFilter(sortDefinition("source_lpl_desc"), { value: null, id: "product-b" }))
      .toBe("and(source_lpl_30.is.null,id.lt.product-b)");
  });

  it("maps Cloudflare cron triggers to the expected GitHub workflows", () => {
    expect(workflowForCron("17 */6 * * *")).toBe("sync-catalog.yml");
    expect(workflowForCron("47 * * * *")).toBe("sync-product-metadata.yml");
    expect(() => workflowForCron("0 0 * * *")).toThrow("Nežinomas cron grafikas");
  });

  it("maps product detail sync rows without exposing raw payloads", () => {
    const detail = mapProductDetail(
      { status: "complete", parser_version: 2, static_synced_at: "2026-07-07T10:00:00Z", availability_synced_at: "2026-07-07T10:00:00Z" },
      [{ section_key: "measurements", source_label: "Išmatavimai", status: "present", items: [{ label: "Ilgis", value: "69cm", unit: "cm", rawText: "Ilgis: 69cm" }] }],
      [{ external_id: "38905", label: "Juoda", url: null, selected: true }],
      [{ external_id: "1", label: "S", size_group: "Standartinis", selected: false, selectable: true, availability: "inStock" }]
    );
    expect(detail).toMatchObject({
      status: "complete", parserVersion: 2,
      sections: [{ key: "measurements", status: "present" }],
      colorOptions: [{ label: "Juoda", selected: true }],
      sizeOptions: [{ externalId: "1", selectable: true, availability: "inStock" }]
    });
    expect(detail).not.toHaveProperty("payload");
  });

  it("maps the sanitized raw payload only for the dedicated debug response", () => {
    const product = {
      id: "00000000-0000-4000-8000-000000000001", external_id: "123", name: "Test", brand: "Brand",
      product_url: "https://www.aboutyou.lt/p/test", image_urls: [], color_original: "Juoda", color_family: "black",
      color_shade: "black", categories: ["Marškiniai"], sizes: ["M"], other_sizes: [], materials: ["Medvilnė"],
      patterns: [], features: [], styles: [], product_types: ["Marškiniai"], source: "aboutyou-lt", current_price: 1000,
      original_price: null, source_lpl_30: null, observed_min_30d: null, discount_pct: 0, currency: "EUR",
      updated_at: "2026-07-08T00:00:00Z", first_seen_at: "2026-07-08T00:00:00Z"
    };
    const withRaw = mapProductDebug(product, null, [], [], [], {
      payload: { imagesSection: { images: [] } }, payload_hash: "abc", fetched_at: "2026-07-08T00:00:00Z",
      source_endpoint: "https://www.aboutyou.lt/p/test", parser_version: 2
    });
    expect(withRaw.raw).toEqual(expect.objectContaining({ payload: { imagesSection: { images: [] } }, parserVersion: 2 }));
    expect(withRaw.rawAvailable).toBe(true);
    expect(mapProductDebug(product, null, [], [], [], null).rawAvailable).toBe(false);
    expect(mapProductDebug(product, null, [], [], [], null).raw).toBeNull();
  });

  it("downloads and expands a private raw artifact", async () => {
    const payload = { imagesSection: { images: [{ image: { src: "https://cdn.example/image.jpg" } }] } };
    const compressed = await new Response(
      new Blob([JSON.stringify(payload)]).stream().pipeThrough(new CompressionStream("gzip"))
    ).blob();
    const db = {
      storage: { from: () => ({ download: async () => ({ data: compressed, error: null }) }) }
    } as unknown as SupabaseClient;
    const raw = await downloadRawArtifact(db, {
      storage_path: "samples/v2/product/hash.json.gz", payload_hash: "hash",
      created_at: "2026-07-11T12:00:00Z", source_endpoint: "source", parser_version: 2
    });
    expect(raw).toEqual(expect.objectContaining({ payload, parser_version: 2 }));
  });

  it("returns no raw payload when a stored artifact is corrupt", async () => {
    const db = {
      storage: { from: () => ({ download: async () => ({ data: new Blob(["not-gzip"]), error: null }) }) }
    } as unknown as SupabaseClient;
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined);
    await expect(downloadRawArtifact(db, { storage_path: "broken.gz" })).resolves.toBeNull();
    consoleError.mockRestore();
  });

  it("explains source breadcrumbs and image persistence for product debug", () => {
    const source = inspectProductDebugPayload({
      linksSection: { breadcrumbs: [
        { label: "Vyrams", url: { url: "/c/vyrams-20202" } },
        { label: "Marškinėliai", url: { url: "/c/vyrams/drabuziai/marskineliai-20324" } },
        { label: "Brandas", url: { url: "/c/vyrams/drabuziai?brand=test" } }
      ] },
      imagesSection: { images: [
        { image: { src: "https://cdn.example/front.jpg" } },
        { image: { src: "https://cdn.example/back.jpg" } },
        { unexpected: true }
      ] }
    }, ["https://cdn.example/front.jpg"]);

    expect(source.breadcrumbs).toEqual([
      expect.objectContaining({ position: 0, label: "Vyrams", accepted: true }),
      expect.objectContaining({ position: 1, label: "Marškinėliai", accepted: true }),
      expect.objectContaining({ position: 2, accepted: false, rejectionReason: "URL turi filtravimo parametrus" })
    ]);
    expect(source.images).toEqual([
      { position: 0, url: "https://cdn.example/front.jpg", stored: true },
      { position: 1, url: "https://cdn.example/back.jpg", stored: false },
      { position: 2, url: null, stored: false }
    ]);
  });

  it("dispatches a GitHub workflow on the configured ref", async () => {
    let request: Request | undefined;
    const fetcher: typeof fetch = async (input, init) => {
      request = new Request(input, init);
      return new Response(JSON.stringify({ workflow_run_id: 123 }), { status: 200 });
    };

    await dispatchGitHubWorkflow("sync-catalog.yml", {
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
      ALLOWED_ORIGIN: "http://localhost:3000",
      GITHUB_TOKEN: "test-token",
      GITHUB_OWNER: "mokinys98",
      GITHUB_REPO: "AboutYou",
      GITHUB_REF: "main"
    }, fetcher);

    expect(request?.url).toBe("https://api.github.com/repos/mokinys98/AboutYou/actions/workflows/sync-catalog.yml/dispatches");
    expect(request?.method).toBe("POST");
    expect(request?.headers.get("authorization")).toBe("Bearer test-token");
    await expect(request?.json()).resolves.toEqual({ ref: "main" });
  });

  it("fails clearly when GitHub rejects a dispatch", async () => {
    const fetcher: typeof fetch = async () => new Response("forbidden", { status: 403 });
    await expect(dispatchGitHubWorkflow("sync-catalog.yml", {
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
      ALLOWED_ORIGIN: "http://localhost:3000",
      GITHUB_TOKEN: "test-token",
      GITHUB_OWNER: "mokinys98",
      GITHUB_REPO: "AboutYou",
      GITHUB_REF: "main"
    }, fetcher)).rejects.toThrow("GitHub workflow sync-catalog.yml paleisti nepavyko (403)");
  });
});
