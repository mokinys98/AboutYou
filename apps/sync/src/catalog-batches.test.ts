import { describe, expect, it, vi } from "vitest";
import { saveCatalogBatchResilient } from "./catalog-batches";

describe("resilient catalog batches", () => {
  it("retries transient errors without duplicate saves", async () => {
    let attempts = 0;
    const result = await saveCatalogBatchResilient({
      items: [{ externalId: "a" }, { externalId: "b" }],
      save: async (items) => {
        attempts += 1;
        if (attempts === 1) throw { code: "57014", message: "timeout" };
        return items.length;
      },
      sleep: async () => undefined
    });
    expect(attempts).toBe(2);
    expect(result).toEqual({ saved: 2, rejected: [] });
  });

  it("bisects deterministic failures and rejects only the bad singleton", async () => {
    const saved: string[][] = [];
    const failures: unknown[] = [];
    let badSingletonAttempts = 0;
    const result = await saveCatalogBatchResilient({
      items: [{ externalId: "a" }, { externalId: "bad" }, { externalId: "c" }, { externalId: "d" }],
      save: async (items) => {
        if (items.some((item) => item.externalId === "bad")) {
          if (items.length === 1) badSingletonAttempts += 1;
          throw { code: "23514", message: "invalid product" };
        }
        saved.push(items.map((item) => item.externalId ?? ""));
        return items.length;
      },
      onFailure: (event) => failures.push(event),
      sleep: async () => undefined
    });
    expect(result.saved).toBe(3);
    expect(result.rejected[0]?.externalId).toBe("bad");
    expect(badSingletonAttempts).toBe(1);
    expect(saved.flat()).toEqual(["a", "c", "d"]);
    expect(failures.length).toBeGreaterThan(0);
  });

  it("does not bisect an unknown error after its diagnostic retry", async () => {
    const save = vi.fn(async () => { throw { message: "unexpected provider response" }; });
    await expect(saveCatalogBatchResilient({ items: [{ externalId: "a" }, { externalId: "b" }], save, sleep: async () => undefined })).rejects.toThrow();
    expect(save).toHaveBeenCalledTimes(2);
  });
});
