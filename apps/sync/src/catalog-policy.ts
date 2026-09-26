import type { CollectionResult } from "@catalog/aboutyou-provider";

export type CatalogCollectionDecision = {
  accepted: boolean;
  reconciliationEligible: boolean;
  quality: "exact" | "coverage_accepted" | "rejected";
  coverage: number | null;
  issue: string | null;
};

export const CATALOG_ACCEPTED_COVERAGE = 0.99;

// A near-complete result is accepted only when the direct stream explicitly
// reached its natural end. Timeout/stall/fallback results must remain retryable.
export function catalogCollectionDecision(result: CollectionResult, limit: number): CatalogCollectionDecision {
  const coverage = result.expectedTotal && result.expectedTotal > 0
    ? result.products.length / result.expectedTotal
    : null;
  const rejected = (issue: string): CatalogCollectionDecision => ({
    accepted: false, reconciliationEligible: false, quality: "rejected", coverage, issue
  });

  if (result.rateLimited) return rejected(result.error || "ABOUT YOU limited requests (HTTP 403/429).");
  if (result.expectedTotal === null || result.expectedTotal <= 0) {
    return rejected("The source did not provide a valid expected product total.");
  }
  if (result.expectedTotal > limit) {
    return rejected(`Collection limit reached: ${result.products.length}/${result.expectedTotal} (limit ${limit}).`);
  }
  if (result.products.length >= result.expectedTotal && result.complete) {
    return { accepted: true, reconciliationEligible: true, quality: "exact", coverage, issue: null };
  }
  const acceptedCount = Math.ceil(result.expectedTotal * CATALOG_ACCEPTED_COVERAGE);
  if (result.mode === "direct-stream" && result.terminationReason === "stream-exhausted" &&
      result.products.length >= acceptedCount) {
    return { accepted: true, reconciliationEligible: false, quality: "coverage_accepted", coverage, issue: null };
  }
  return rejected(result.error || `Incomplete collection: ${result.products.length}/${result.expectedTotal}.`);
}

export function catalogCollectionIssue(result: CollectionResult, limit: number): string | null {
  return catalogCollectionDecision(result, limit).issue;
}
