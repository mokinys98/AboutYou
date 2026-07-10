import { describe, expect, it } from "vitest";
import type { ProductDetailExtraction } from "@catalog/aboutyou-provider";
import { classifyMetadataExtraction } from "./metadata-policy";

function extraction(overrides: Partial<ProductDetailExtraction> = {}): ProductDetailExtraction {
  return {
    metadata: {
      colorOriginal: null, categories: [], imageUrls: [], sizes: [], otherSizes: [], materials: [],
      patterns: [], features: [], styles: [], productTypes: [], isPremium: false, sections: [], colorOptions: [], sizeOptions: []
    },
    rawPayload: { imagesSection: {} },
    payloadHash: "a".repeat(64),
    sourceProductId: "123",
    schemaError: null,
    ...overrides
  };
}

describe("metadata extraction failure policy", () => {
  it("retries an HTML response without a product payload", () => {
    expect(classifyMetadataExtraction(extraction({ rawPayload: null, payloadHash: null }), "123"))
      .toEqual({ kind: "retryable", code: "product_detail_payload_missing" });
  });

  it("retries a payload identity mismatch", () => {
    expect(classifyMetadataExtraction(extraction({ sourceProductId: "456" }), "123"))
      .toEqual({ kind: "retryable", code: "product_detail_id_mismatch" });
  });

  it("blocks only a confirmed unsupported payload schema", () => {
    expect(classifyMetadataExtraction(extraction({ schemaError: "unknown_detail_lane:futureLane" }), "123"))
      .toEqual({ kind: "blocked_schema", code: "unknown_detail_lane:futureLane" });
  });

  it("accepts a valid extraction", () => {
    expect(classifyMetadataExtraction(extraction(), "123")).toBeNull();
  });
});
