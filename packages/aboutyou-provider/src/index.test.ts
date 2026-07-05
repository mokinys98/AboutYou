import { describe, expect, it } from "vitest";
import { decodeGrpcWebFrames, extractColorFromProductHtml, extractProductMetadataFromHtml, normalizeRawProduct } from "./index";

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
      "@type":"ProductGroup","category":"Kasdieniniai marškiniai",
      "hasVariant":[{"@type":"Product","color":"smėlio spalva","size":"M"}]
    }</script>`;
    expect(extractColorFromProductHtml(html)).toBe("smėlio spalva");
    expect(extractProductMetadataFromHtml(html).categories).toEqual(["Kasdieniniai marškiniai"]);
  });

  it("falls back to the rendered selected color", () => {
    const html = `<span data-testid="productColorInfoSelectedOptionName">tamsiai m&amp;ėlyna</span>`;
    expect(extractColorFromProductHtml(html)).toBe("tamsiai m&ėlyna");
  });

  it("extracts the primary category path from product JSON-LD breadcrumbs", () => {
    const html = `<script type="application/ld+json">{
      "@type":"BreadcrumbList","itemListElement":[
        {"@type":"ListItem","position":1,"item":{"@id":"https://www.aboutyou.lt/c/vyrams-20202","name":"Vyrams"}},
        {"@type":"ListItem","position":2,"item":{"@id":"https://www.aboutyou.lt/c/vyrams/drabuziai-20290","name":"Drabužiai"}},
        {"@type":"ListItem","position":3,"item":{"@id":"https://www.aboutyou.lt/c/vyrams/drabuziai/marskiniai-20319","name":"Marškiniai"}},
        {"@type":"ListItem","position":4,"item":{"@id":"https://www.aboutyou.lt/c/vyrams/drabuziai/marskiniai/kasdieniniai-marskiniai-23687","name":"Kasdieniniai marškiniai"}},
        {"@type":"ListItem","position":5,"item":{"@id":"https://www.aboutyou.lt/c/vyrams/drabuziai/marskiniai/kasdieniniai-marskiniai-23687?brand=jack-jones-1122","name":"JACK & JONES Kasdieniniai marškiniai"}},
        {"@type":"ListItem","position":6,"item":{"@id":"https://www.aboutyou.lt/p/jack-jones/marskiniai-jjglobal-31740818","name":"Marškiniai JJGlobal"}}
      ]
    }</script>`;
    expect(extractProductMetadataFromHtml(html).categories).toEqual([
      "Drabužiai", "Marškiniai", "Kasdieniniai marškiniai"
    ]);
  });
});
