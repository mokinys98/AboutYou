import { describe, expect, it } from "vitest";
import { buildCategoryTree, catalogRootCategories, cents, expandClothingCategoryPath, isAllowedAboutYouUrl, normalizeCategoryPath, normalizeColor, normalizeColorShade, ProductSchema } from "./index";

describe("shared catalog rules", () => {
  it("parses localized euro prices", () => {
    expect(cents("1 299,95 €")).toBe(129995);
    expect(cents("39 €")).toBe(3900);
  });

  it("normalizes common colors", () => {
    expect(normalizeColor("Tamsiai mėlyna")).toBe("blue");
    expect(normalizeColor("Smėlio spalva")).toBe("beige");
  });

  it("keeps specific marketed shades separate", () => {
    expect(normalizeColorShade("Teal")).toBe("teal");
    expect(normalizeColorShade("Alyvuogių žalia")).toBe("olive");
    expect(normalizeColorShade("Rust")).toBe("rust");
    expect(normalizeColorShade("Vario spalva")).toBe("copper");
    expect(normalizeColorShade("Visiškai nežinoma")).toBe("other");
    expect(normalizeColor("Teal")).toBe("green");
    expect(normalizeColor("Rust")).toBe("orange");
  });

  it("restricts sync URLs", () => {
    expect(isAllowedAboutYouUrl("https://www.aboutyou.lt/c/moterims-20201")).toBe(true);
    expect(isAllowedAboutYouUrl("https://example.com/aboutyou.lt")).toBe(false);
  });

  it("expands an ABOUT YOU leaf category to the left-menu hierarchy", () => {
    expect(expandClothingCategoryPath(["Kasdieniniai marškiniai"])).toEqual([
      "Drabužiai", "Marškiniai", "Kasdieniniai marškiniai"
    ]);
  });

  it("keeps non-clothing root categories available to the catalog menu", () => {
    expect(expandClothingCategoryPath(["Vyrams", "Batai", "Sportbačiai"])).toEqual([
      "Batai", "Sportbačiai"
    ]);
    expect(catalogRootCategories).toContain("Batai");
  });

  it("preserves an exact four-level breadcrumb and creates a provisional root path", () => {
    expect(normalizeCategoryPath(["Vyrams", "Drabužiai", "Marškiniai", "Kasdieniniai marškiniai"])).toEqual([
      "Vyrams", "Drabužiai", "Marškiniai", "Kasdieniniai marškiniai"
    ]);
    expect(normalizeCategoryPath(["Sportbačiai"], "Batai")).toEqual(["Vyrams", "Batai", "Sportbačiai"]);
  });

  it("groups duplicate labels by parent and prioritizes catalog roots", () => {
    const tree = buildCategoryTree([
      { id: "accessories", parentId: null, name: "Aksesuarai", level: 2, path: "vyrams>aksesuarai", count: 2 },
      { id: "clothes", parentId: null, name: "Drabužiai", level: 2, path: "vyrams>drabužiai", count: 4 },
      { id: "sports", parentId: "clothes", name: "Sportiniai", level: 3, path: "vyrams>drabužiai>sportiniai", count: 1 },
      { id: "sports-accessories", parentId: "accessories", name: "Sportiniai", level: 3, path: "vyrams>aksesuarai>sportiniai", count: 1 }
    ]);
    expect(tree.map((item) => item.name)).toEqual(["Drabužiai", "Aksesuarai"]);
    expect(tree[0]?.children[0]?.id).toBe("sports");
    expect(tree[1]?.children[0]?.id).toBe("sports-accessories");
  });

  it("rejects invalid product data", () => {
    expect(ProductSchema.safeParse({ externalId: "1" }).success).toBe(false);
  });
});
