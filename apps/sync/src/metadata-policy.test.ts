import { describe, expect, it } from "vitest";
import type { ProductDetailExtraction } from "@catalog/aboutyou-provider";
import {
  classifyMetadataExtraction, metadataContextAction, metadataRunFailed, shouldStopMetadataBatch
} from "./metadata-policy";

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
  it("stops a systemic failure before thousands of products are retried", () => {
    const counts = { claimed: 25, complete: 0, retryable: 25, blocked_schema: 0 };
    expect(shouldStopMetadataBatch(counts)).toBe(true);
    expect(metadataRunFailed(counts, false)).toBe(true);
    expect(shouldStopMetadataBatch({ ...counts, complete: 1 })).toBe(false);
    expect(shouldStopMetadataBatch({ ...counts, retryable: 0 })).toBe(false);
  });

  it("fails partial and rate-limited runs but allows an empty queue", () => {
    const counts = { claimed: 0, complete: 0, retryable: 0, blocked_schema: 0 };
    expect(metadataRunFailed(counts, false)).toBe(false);
    expect(metadataRunFailed(counts, true)).toBe(true);
    expect(metadataRunFailed({ ...counts, complete: 24, retryable: 1 }, false)).toBe(true);
    expect(metadataRunFailed({ ...counts, blocked_schema: 1 }, false)).toBe(true);
  });

  it("rotates contexts on schedule and opens the circuit after three timeout recoveries", () => {
    const base = {
      attemptsInContext: 99, maxAttemptsInContext: 100, timeoutThresholdReached: false,
      timeoutRecoveries: 0, maxTimeoutRecoveries: 3
    };
    expect(metadataContextAction(base)).toBe("continue");
    expect(metadataContextAction({ ...base, attemptsInContext: 100 })).toBe("rotate-scheduled");
    expect(metadataContextAction({ ...base, timeoutThresholdReached: true })).toBe("recover-timeout");
    expect(metadataContextAction({ ...base, timeoutThresholdReached: true, timeoutRecoveries: 2 })).toBe("open-circuit");
  });

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
