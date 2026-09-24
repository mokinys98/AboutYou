import { describe, expect, it } from "vitest";
import { CATALOG_DB_BATCH_SIZE, CatalogQueueEnvSchema, retryDelayMinutes } from "./catalog-queue";

describe("catalog queue retry policy", () => {
  it("uses bounded backoff before a task is blocked by the database after attempt five", () => {
    expect([1, 2, 3, 4, 5].map(retryDelayMinutes)).toEqual([5, 15, 60, 60, 60]);
  });

  it("collects the full supported target and starts with database-safe batches", () => {
    const env = CatalogQueueEnvSchema.parse({
      SUPABASE_URL: "https://example.supabase.co",
      SUPABASE_SERVICE_ROLE_KEY: "test-service-role-key"
    });
    expect(env.SYNC_MAX_PRODUCTS).toBe(15_000);
    expect(CATALOG_DB_BATCH_SIZE).toBe(100);
  });
});
