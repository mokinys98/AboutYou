import { describe, expect, it } from "vitest";
import { decodeRawPayload, encodeRawPayload, rawArtifactPath } from "./metadata-artifacts";

describe("metadata raw artifacts", () => {
  it("round-trips a gzip JSON payload and computes a stable content hash", async () => {
    const payload = { product: { id: 123, labels: Array.from({ length: 100 }, () => "repeated-product-label") }, available: true };
    const first = await encodeRawPayload(payload);
    const decoded = await decodeRawPayload(first.compressed);
    const second = await encodeRawPayload(decoded);

    expect(decoded).toEqual(payload);
    expect(first.contentHash).toMatch(/^[0-9a-f]{64}$/);
    expect(second.contentHash).toBe(first.contentHash);
    expect(first.compressedSize).toBeLessThan(first.uncompressedSize);
  });

  it("uses content-addressed stable paths for samples", () => {
    const hash = "a".repeat(64);
    expect(rawArtifactPath("success_sample", 2, "product-id", hash))
      .toBe(`samples/v2/product-id/${hash}.json.gz`);
    expect(rawArtifactPath("blocked_schema", 3, "product-id", hash, new Date("2026-07-11T12:00:00Z")))
      .toBe(`blocked-schema/2026-07-11/v3/product-id/${hash}.json.gz`);
  });
});
