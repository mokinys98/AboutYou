import { describe, expect, it } from "vitest";
import app from "./index";

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
});
