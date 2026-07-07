import { describe, expect, it } from "vitest";
import { app, catalogCacheUrl, dispatchGitHubWorkflow, mapProductDetail, newestCatalogCutoff, parseFilters, priceComparisonColumn, workflowForCron } from "./index";

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

  it("protects catalog routes", async () => {
    const response = await app.request("/v1/catalog", {}, {
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
      ALLOWED_ORIGIN: "http://localhost:3000"
    });
    expect(response.status).toBe(401);
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

  it("parses detailed colors and the source LPL comparison", () => {
    const parsed = parseFilters({ color_shades: "teal,olive", below_observed_30d: "true", price_comparison: "source_lpl" });
    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data.colorShades).toEqual(["teal", "olive"]);
      expect(parsed.data.priceComparison).toBe("source_lpl");
      expect(parsed.data.belowObserved30d).toBe(true);
    }
    expect(priceComparisonColumn("source_lpl")).toBe("below_source_lpl_30d");
    expect(priceComparisonColumn("observed")).toBe("below_observed_30d");
  });

  it("parses a stable category path separately from legacy category names", () => {
    const parsed = parseFilters({ category: "vyrams%3Edrabu%C5%BEiai", categories: "Marškiniai" });
    expect(parsed.success).toBe(true);
    if (parsed.success) {
      expect(parsed.data.categoryPath).toBe("vyrams>drabužiai");
      expect(parsed.data.categories).toEqual(["Marškiniai"]);
    }
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
