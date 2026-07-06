import { describe, expect, it } from "vitest";
import app, { catalogCacheUrl, newestCatalogCutoff, parseFilters, priceComparisonColumn } from "./index";

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
});
