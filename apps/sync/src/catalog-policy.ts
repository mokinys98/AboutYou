import type { CollectionResult } from "@catalog/aboutyou-provider";

// Only full coverage may advance missing-product counters in finish_sync_run.
export function catalogCollectionIssue(result: CollectionResult, limit: number): string | null {
  if (result.rateLimited) return result.error || "ABOUT YOU apribojo užklausas (403/429).";
  if (!result.complete) return result.error || `Nepilnas rinkimas: ${result.products.length}/${result.expectedTotal ?? "?"}.`;
  if (result.expectedTotal === null) return "Nežinomas bendras prekių skaičius; pilna aprėptis nepatvirtinta.";
  if (result.expectedTotal > limit || result.products.length < result.expectedTotal) {
    return `Pasiekta rinkimo riba arba trūksta prekių: ${result.products.length}/${result.expectedTotal} (riba ${limit}).`;
  }
  return null;
}
