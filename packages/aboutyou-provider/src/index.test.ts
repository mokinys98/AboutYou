import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  decodeGrpcWebFrames, extractColorFromProductHtml, extractProductDetailFromHtml,
  extractProductDetailPayloadFromHtml, extractProductMetadataFromHtml, hashProductDetailPayload, normalizeRawProduct,
  PRODUCT_DETAIL_ENDPOINT, PRODUCT_DETAIL_PARSER_VERSION
} from "./index";

const productDetailFixture = readFileSync(
  fileURLToPath(new URL("./fixtures/product-detail-initial-state.html", import.meta.url)), "utf8"
);

function htmlForPayload(payload: Record<string, unknown>): string {
  return `<script data-tadarida-initial-state="true">${JSON.stringify([
    [PRODUCT_DETAIL_ENDPOINT + ":test", { data: payload }]
  ])}</script>`;
}

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
      "hasVariant":[{"@type":"Product","color":"smėlio spalva","size":"M","material":"Medvilnė","pattern":"Vienspalvis"}]
    }</script>`;
    expect(extractColorFromProductHtml(html)).toBe("smėlio spalva");
    expect(extractProductMetadataFromHtml(html).categories).toEqual(["Kasdieniniai marškiniai"]);
    expect(extractProductMetadataFromHtml(html)).toMatchObject({
      sizes: ["M"], materials: ["Medvilnė"], patterns: ["Vienspalvis"]
    });
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
      "Vyrams", "Drabužiai", "Marškiniai", "Kasdieniniai marškiniai"
    ]);
  });

  it("extracts and sanitizes the product detail API payload", () => {
    const result = extractProductDetailFromHtml(productDetailFixture);

    expect(result.rawPayload).not.toBeNull();
    expect(result.rawPayload).not.toHaveProperty("trailers");
    expect(result.rawPayload).not.toHaveProperty("campaigns");
    expect(result.rawPayload).not.toHaveProperty("title");
    expect(result.payloadHash).toMatch(/^[0-9a-f]{64}$/);
    expect(PRODUCT_DETAIL_ENDPOINT).toContain("ArticleDetailService/GetProductBulk");
    expect(PRODUCT_DETAIL_PARSER_VERSION).toBe(4);
  });

  it("extracts explicit product fields from a sanitized real payload fixture", () => {
    const metadata = extractProductDetailFromHtml(productDetailFixture).metadata;

    expect(metadata).toMatchObject({
      colorOriginal: "juoda",
      categories: ["Vyrams", "Drabužiai", "Marškinėliai"],
      sizes: ["S Standartinis", "M Standartinis"],
      otherSizes: ["Standartinis"],
      materials: ["60% Medvilnė, 40% Poliesteris"],
      features: ["Vienspalvis", "Plonas trikotažas", "Orui laidus"],
      styles: ["Ilgis: normalus"],
      productTypes: ["Marškinėliai"]
    });
    expect(metadata.imageUrls[0]).toBe("https://cdn.aboutstatic.com/product-front.jpg?quality=75&trim=1");
    expect(metadata.sections).toEqual(expect.arrayContaining([
      expect.objectContaining({ key: "size_and_fit", status: "present" }),
      expect.objectContaining({ key: "measurements", status: "present" }),
      expect.objectContaining({ key: "material_composition", status: "present" }),
      expect.objectContaining({ key: "design_and_extras", status: "present" })
    ]));
    expect(metadata.sizeOptions).toEqual([
      expect.objectContaining({ externalId: "1", group: "Standartinis", selectable: true, availability: "inStock" }),
      expect.objectContaining({ externalId: "2", group: "Standartinis", selectable: false, availability: "soldOut" })
    ]);
    expect(metadata.colorOptions).toEqual([
      expect.objectContaining({ externalId: "3935028", selected: true, url: "https://www.aboutyou.lt/p/under-armour/marskineliai-3935028" }),
      expect.objectContaining({ externalId: "3990667", selected: false, label: "tamsiai mėlyna" })
    ]);
  });

  it("accepts the extra JSON-encoded endpoint key used by live initial state", () => {
    const quotedKeyFixture = productDetailFixture.replace(
      '"aysa_api.services.article_detail_page.v1.ArticleDetailService/GetProductBulk:fixture"',
      '"\\\"aysa_api.services.article_detail_page.v1.ArticleDetailService/GetProductBulk:fixture\\\""'
    );
    const result = extractProductDetailFromHtml(quotedKeyFixture);
    expect(result.rawPayload).not.toBeNull();
    expect(result.sourceProductId).toBe("3935028");
    expect(result.schemaError).toBeNull();
  });

  it("blocks an unknown product-detail lane instead of accepting partial metadata", () => {
    const unknownLaneFixture = productDetailFixture.replace(
      '"lanes":[',
      '"lanes":[{"label":"Nauja sekcija","type":{"$case":"futureLane","futureLane":{"items":["x"]}}},'
    );
    expect(extractProductDetailFromHtml(unknownLaneFixture).schemaError).toBe("unknown_detail_lane:futureLane");
  });

  it("supports noSiblings color selection and singleDimension sizes", () => {
    const payload = extractProductDetailPayloadFromHtml(productDetailFixture) as Record<string, any>;
    payload.productSelectionSection = {
      type: { $case: "noSiblings", noSiblings: { colorLabel: "juoda" } }
    };
    for (const productSize of payload.imagesSection.product.sizes) {
      const dimension = productSize.shopSize.size.twoDimension.firstDimension;
      productSize.shopSize.size = { $case: "singleDimension", singleDimension: { dimension } };
    }

    const extraction = extractProductDetailFromHtml(htmlForPayload(payload));
    expect(extraction.schemaError).toBeNull();
    expect(extraction.metadata.colorOptions).toEqual([
      expect.objectContaining({ externalId: "3935028", label: "juoda", selected: true })
    ]);
    expect(extraction.metadata.sizeOptions.every((option) => option.group === null)).toBe(true);
  });

  it("supports the sustainabilityInfoLane used by product 28539045", () => {
    const payload = extractProductDetailPayloadFromHtml(productDetailFixture) as Record<string, any>;
    payload.productDetailsSection.articleDetails.lanes.push({
      label: "Gaminio yra: 95% regeneraciniu būdu užauginta medžiaga",
      type: {
        $case: "sustainabilityInfoLane",
        sustainabilityInfoLane: { cluster: { attributes: [
          { label: "Pagaminta su:", text: "Medvilnė" },
          { label: "Įrodymai:", text: "Tiekėjo deklaracija" }
        ] } }
      }
    });

    const extraction = extractProductDetailFromHtml(htmlForPayload(payload));
    expect(extraction.schemaError).toBeNull();
    expect(extraction.metadata.sections).toEqual(expect.arrayContaining([
      expect.objectContaining({
        key: "design_and_extras",
        items: expect.arrayContaining([expect.objectContaining({ rawText: "Pagaminta su: Medvilnė" })])
      })
    ]));
  });

  it("uses the shop size run without duplicating vendor sizes for product 24458375", () => {
    const payload = extractProductDetailPayloadFromHtml(productDetailFixture) as Record<string, any>;
    payload.sizesSection.sizeSelection.type = {
      $case: "sizeRuns",
      sizeRuns: { sizeRuns: [
        { label: "Gamintojo dydis", sizes: [{ sizeId: 1, label: "XL", availability: { $case: "inStock" } }], sizeSource: { type: { $case: "vendor" } } },
        { label: "Coliai", sizes: [{ sizeId: 1, label: "35-36", availability: { $case: "inStock" } }], sizeSource: { type: { $case: "shop" } } }
      ] }
    };

    const extraction = extractProductDetailFromHtml(htmlForPayload(payload));
    expect(extraction.schemaError).toBeNull();
    expect(extraction.metadata.sizes).toEqual(["35-36"]);
    expect(extraction.metadata.sizeOptions).toEqual([
      expect.objectContaining({ externalId: "1", label: "35-36", selectable: true })
    ]);
  });

  it("supports the oneSize selection used by product 17554552", () => {
    const payload = extractProductDetailPayloadFromHtml(productDetailFixture) as Record<string, any>;
    payload.sizesSection.sizeSelection.type = {
      $case: "oneSize",
      oneSize: { size: { sizeId: 1, label: "Vienas dydis", availability: { $case: "inStock" } } }
    };

    const extraction = extractProductDetailFromHtml(htmlForPayload(payload));
    expect(extraction.schemaError).toBeNull();
    expect(extraction.metadata.sizes).toEqual(["Vienas dydis"]);
    expect(extraction.metadata.sizeOptions[0]).toEqual(expect.objectContaining({ selectable: true }));
  });

  it("uses the trouser length as the size group for product 31756823", () => {
    const payload = extractProductDetailPayloadFromHtml(productDetailFixture) as Record<string, any>;
    payload.imagesSection.product.sizes[0].shopSize.size = {
      $case: "pants", pants: { width: "28", length: "30", label: "28 x 30" }
    };
    payload.sizesSection.product = payload.imagesSection.product;

    const extraction = extractProductDetailFromHtml(htmlForPayload(payload));
    expect(extraction.schemaError).toBeNull();
    expect(extraction.metadata.sizeOptions[0]).toEqual(expect.objectContaining({ group: "30" }));
    expect(extraction.metadata.otherSizes).toContain("30");
  });

  it("hashes equivalent JSON objects deterministically", () => {
    expect(hashProductDetailPayload({ b: 2, a: { d: 4, c: 3 } }))
      .toBe(hashProductDetailPayload({ a: { c: 3, d: 4 }, b: 2 }));
    expect(hashProductDetailPayload({ availability: "in_stock" }))
      .not.toBe(hashProductDetailPayload({ availability: "sold_out" }));
  });

  it("keeps JSON-LD metadata as fallback when the product API payload is missing", () => {
    const html = `<script type="application/ld+json">{"@type":"Product","color":"žalia","material":"Linas"}</script>`;
    const result = extractProductDetailFromHtml(html);

    expect(result.rawPayload).toBeNull();
    expect(result.payloadHash).toBeNull();
    expect(result.metadata.colorOriginal).toBe("žalia");
    expect(result.metadata.materials).toEqual(["Linas"]);
  });
});
