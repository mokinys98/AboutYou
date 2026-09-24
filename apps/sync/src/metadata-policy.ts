import type { ProductDetailExtraction } from "@catalog/aboutyou-provider";

export type MetadataFailure = {
  kind: "retryable" | "blocked_schema";
  code: string;
};

type RunCounts = { claimed: number; complete: number; retryable: number; blocked_schema: number };

export function shouldStopMetadataBatch(counts: RunCounts): boolean {
  return counts.claimed >= 25 && counts.complete === 0 && counts.retryable + counts.blocked_schema >= 20;
}

export function shouldOpenMetadataTimeoutCircuit(
  counts: Pick<RunCounts, "complete">,
  consecutiveTimeouts: number,
  threshold: number
): boolean {
  return counts.complete > 0 && consecutiveTimeouts >= threshold;
}

export function metadataRunFailed(counts: RunCounts, rateLimited: boolean): boolean {
  return rateLimited || counts.retryable > 0 || counts.blocked_schema > 0;
}

export function classifyMetadataExtraction(
  extraction: ProductDetailExtraction,
  expectedExternalId: string
): MetadataFailure | null {
  if (!extraction.rawPayload || !extraction.payloadHash) {
    return { kind: "retryable", code: "product_detail_payload_missing" };
  }
  if (extraction.sourceProductId !== expectedExternalId) {
    return { kind: "retryable", code: "product_detail_id_mismatch" };
  }
  if (extraction.schemaError) {
    return { kind: "blocked_schema", code: extraction.schemaError };
  }
  return null;
}
