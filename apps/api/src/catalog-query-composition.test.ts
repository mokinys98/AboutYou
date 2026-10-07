import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { app, postgresArrayLiteral } from "./index";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("catalog query filter composition", () => {
  it("keeps size groups and other sizes as AND filters while OR-ing grouped and legacy sizes", async () => {
    const { privateKey, publicKey } = await generateKeyPair("RS256");
    const keyId = "catalog-query-test";
    const jwk = await exportJWK(publicKey);
    const token = await new SignJWT({ role: "authenticated" })
      .setProtectedHeader({ alg: "RS256", kid: keyId })
      .setSubject("00000000-0000-4000-8000-000000000001")
      .setIssuer("https://catalog-query-test.supabase.co/auth/v1")
      .setIssuedAt()
      .setExpirationTime("5m")
      .sign(privateKey);

    let catalogRequestUrl: URL | undefined;
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const requestUrl = new URL(input instanceof Request ? input.url : String(input));
      if (requestUrl.pathname.endsWith("/.well-known/jwks.json")) {
        return Response.json({ keys: [{ ...jwk, kid: keyId, alg: "RS256", use: "sig" }] });
      }
      if (requestUrl.pathname.endsWith("/team_members")) {
        return Response.json({ email: "test@example.com", role: "admin", active: true, accepted_at: "2026-10-01T00:00:00Z" });
      }
      if (requestUrl.pathname.endsWith("/catalog_items_read_with_lpl")) {
        catalogRequestUrl = requestUrl;
        return Response.json([], { headers: { "content-range": "*/0" } });
      }
      return Response.json([]);
    });
    vi.stubGlobal("fetch", fetchMock);
    vi.stubGlobal("caches", {
      default: {
        match: async () => undefined,
        put: async () => undefined
      }
    });

    // Match the frontend serializer: commas inside a token are percent-encoded
    // while commas between tokens remain list separators.
    const requestUrl = new URL("https://api.example/v1/catalog");
    requestUrl.searchParams.set("sizes", "shoes%3A42%2C5,shirts%3AM,L");
    requestUrl.searchParams.set("other_sizes", "42%2C5,OneSize,XL");
    requestUrl.searchParams.set("lpl_proximity_pct", "15");
    const response = await app.request(requestUrl, {
      headers: { Authorization: `Bearer ${token}` }
    }, {
      SUPABASE_URL: "https://catalog-query-test.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key",
      ALLOWED_ORIGIN: "http://localhost:3000"
    }, {
      props: {},
      waitUntil: (promise: Promise<unknown>) => void promise,
      passThroughOnException: () => undefined
    });

    expect(response.status).toBe(200);
    expect(catalogRequestUrl).toBeDefined();
    const params = catalogRequestUrl!.searchParams;
    expect(params.get("lpl_price_ratio")).toBe("lte.115");
    expect(params.get("other_sizes")).toBe('ov.{"42,5","OneSize","XL"}');
    expect(params.get("or")).toBe('(size_tokens.ov.{"shoes:42.5","shirts:m"},sizes.ov.{"L"})');
    expect(params.get("size_tokens")).toBeNull();
    expect(params.get("sizes")).toBeNull();
  });

  it("preserves a decimal comma as one other-size array value", async () => {
    let serializedUrl: URL | undefined;
    const db = createClient("https://example.supabase.co", "test-service-role-key", {
      auth: { persistSession: false },
      global: {
        fetch: async (input) => {
          serializedUrl = new URL(input instanceof Request ? input.url : String(input));
          return Response.json([]);
        }
      }
    });

    await db.from("catalog_items_read_with_lpl").select("id")
      .filter("other_sizes", "ov", postgresArrayLiteral(["42,5", "OneSize"]));

    expect(serializedUrl?.searchParams.get("other_sizes")).toBe('ov.{"42,5","OneSize"}');
  });
});
