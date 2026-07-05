import { describe, expect, it } from "vitest";
import { decodeGrpcWebFrames, extractColorFromProductHtml, normalizeRawProduct } from "./index";

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
    expect(product?.colorShade).toBe("navy");
  });

  it("extracts the selected color from product JSON-LD", () => {
    const html = `<script type="application/ld+json">{
      "@type":"ProductGroup","hasVariant":[{"@type":"Product","color":"smėlio spalva","size":"M"}]
    }</script>`;
    expect(extractColorFromProductHtml(html)).toBe("smėlio spalva");
  });

  it("falls back to the rendered selected color", () => {
    const html = `<span data-testid="productColorInfoSelectedOptionName">tamsiai m&amp;ėlyna</span>`;
    expect(extractColorFromProductHtml(html)).toBe("tamsiai m&ėlyna");
  });
});
