import { describe, expect, it } from "vitest";
import { cents, expandClothingCategoryPath, isAllowedAboutYouUrl, normalizeColor, normalizeColorShade, ProductSchema } from "./index";

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

  it("rejects invalid product data", () => {
    expect(ProductSchema.safeParse({ externalId: "1" }).success).toBe(false);
  });
});
