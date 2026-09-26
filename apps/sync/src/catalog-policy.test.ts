import { describe, expect, it } from "vitest";
import type { CollectionResult } from "@catalog/aboutyou-provider";
import { catalogCollectionDecision, catalogCollectionIssue } from "./catalog-policy";

const result = (
  count: number, total: number | null, complete = true,
  terminationReason: CollectionResult["terminationReason"] = complete ? "target-reached" : "stalled"
): CollectionResult => ({
  products: Array.from({ length: count }, () => ({} as CollectionResult["products"][number])),
  pages: 1, expectedTotal: total, complete, mode: "direct-stream", terminationReason
});

describe("catalog coverage before disappearance reconciliation", () => {
  it("accepts full coverage and permits reconciliation", () => {
    expect(catalogCollectionDecision(result(50, 50), 100)).toMatchObject({
      accepted: true, reconciliationEligible: true, quality: "exact", issue: null
    });
  });

  it("accepts 99 percent only after natural direct-stream exhaustion", () => {
    expect(catalogCollectionDecision(result(99, 100, false, "stream-exhausted"), 100)).toMatchObject({
      accepted: true, reconciliationEligible: false, quality: "coverage_accepted"
    });
    expect(catalogCollectionIssue(result(989, 1000, false, "stream-exhausted"), 1000)).not.toBeNull();
    expect(catalogCollectionIssue(result(99, 100, false, "timeout"), 100)).not.toBeNull();
    expect(catalogCollectionIssue({ ...result(99, 100, false, "stream-exhausted"), mode: "scroll-fallback" }, 100)).not.toBeNull();
  });

  it("does not accept a capped diagnostic run", () => {
    expect(catalogCollectionIssue(result(50, 15_000), 50)).not.toBeNull();
  });

  it("rejects unknown totals, stalled streams and normalization losses", () => {
    expect(catalogCollectionIssue(result(50, null), 50)).not.toBeNull();
    expect(catalogCollectionIssue(result(49, 50, false, "stream-exhausted"), 100)).not.toBeNull();
    expect(catalogCollectionIssue(result(50, 50, false), 100)).not.toBeNull();
  });

  it("preserves the rate limit reason even with products collected", () => {
    expect(catalogCollectionIssue({ ...result(50, 50), rateLimited: true, error: "HTTP 429" }, 100)).toBe("HTTP 429");
  });
});
