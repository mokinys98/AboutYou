import { describe, expect, it } from "vitest";
import type { CollectionResult } from "@catalog/aboutyou-provider";
import { catalogCollectionIssue } from "./catalog-policy";

const result = (count: number, total: number | null, complete = true): CollectionResult => ({
  products: Array.from({ length: count }, () => ({} as CollectionResult["products"][number])),
  pages: 1, expectedTotal: total, complete, mode: "direct-stream"
});

describe("catalog coverage before disappearance reconciliation", () => {
  it("accepts full coverage", () => expect(catalogCollectionIssue(result(50, 50), 100)).toBeNull());
  it("does not deactivate unseen products after a capped diagnostic run", () => {
    expect(catalogCollectionIssue(result(50, 15000), 50)).not.toBeNull();
  });
  it("rejects unknown totals, stalled streams and normalization losses", () => {
    expect(catalogCollectionIssue(result(50, null), 50)).not.toBeNull();
    expect(catalogCollectionIssue(result(49, 50), 100)).not.toBeNull();
    expect(catalogCollectionIssue(result(50, 50, false), 100)).not.toBeNull();
  });
  it("preserves the rate limit reason even with products collected", () => {
    expect(catalogCollectionIssue({ ...result(50, 50), rateLimited: true, error: "HTTP 429" }, 100)).toBe("HTTP 429");
  });
});
