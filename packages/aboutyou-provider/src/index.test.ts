import { describe, expect, it } from "vitest";
import { decodeGrpcWebFrames, normalizeRawProduct } from "./index";

describe("ABOUT YOU provider", () => {
  it("decodes data frames and skips trailer frames", () => {
    const input = new Uint8Array([0, 0, 0, 0, 3, 1, 2, 3, 128, 0, 0, 0, 1, 9]);
    expect(Array.from(decodeGrpcWebFrames(input))).toEqual([1, 2, 3]);
  });

  it("normalizes a raw product", () => {
    const product = normalizeRawProduct({
      externalId: "123", name: "Megztinis", brand: "Brand", productUrl: "https://www.aboutyou.lt/p/x-123",
      imageUrls: [], colorOriginal: "Tamsiai mėlyna", categories: ["Megztiniai"], currentPrice: 3999,
      originalPrice: 5999, sourceLpl30: 4499
    });
    expect(product?.colorFamily).toBe("blue");
  });
});
