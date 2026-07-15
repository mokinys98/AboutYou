import { describe, expect, it } from "vitest";
import { loadAdminResources } from "./adminData";

describe("admin data loading", () => {
  it("keeps successful panels available when one endpoint fails", async () => {
    const responses: Record<string, unknown> = {
      "/v1/sync-targets": [{ id: "target-1" }],
      "/v1/sync-runs": [{ id: "run-1" }],
      "/v1/admin/users": [{ email: "admin@example.com" }],
      "/v1/admin/brand-tiers": [{ brandKey: "brand-1" }]
    };
    async function api<T>(path: string): Promise<T> {
      if (path === "/v1/admin/dashboard") throw new Error("Dashboard timeout");
      return responses[path] as T;
    }

    const result = await loadAdminResources(api);

    expect(result.data.dashboard).toBeUndefined();
    expect(result.errors).toEqual({ dashboard: "Dashboard timeout" });
    expect(result.data.syncTargets).toEqual([{ id: "target-1" }]);
    expect(result.data.syncRuns).toEqual([{ id: "run-1" }]);
    expect(result.data.users).toEqual([{ email: "admin@example.com" }]);
    expect(result.data.brandTiers).toEqual([{ brandKey: "brand-1" }]);
  });
});
