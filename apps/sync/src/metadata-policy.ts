import type { ProductDetailExtraction } from "@catalog/aboutyou-provider";

export type MetadataFailure = {
  kind: "retryable" | "blocked_schema";
  code: string;
};

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
