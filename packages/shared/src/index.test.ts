import { describe, expect, it } from "vitest";
import { cents, isAllowedAboutYouUrl, normalizeColor, ProductSchema } from "./index";

describe("shared catalog rules", () => {
  it("parses localized euro prices", () => {
    expect(cents("1 299,95 €")).toBe(129995);
    expect(cents("39 €")).toBe(3900);
  });

  it("normalizes common colors", () => {
    expect(normalizeColor("Tamsiai mėlyna")).toBe("blue");
    expect(normalizeColor("Smėlio spalva")).toBe("beige");
  });

  it("restricts sync URLs", () => {
    expect(isAllowedAboutYouUrl("https://www.aboutyou.lt/c/moterims-20201")).toBe(true);
    expect(isAllowedAboutYouUrl("https://example.com/aboutyou.lt")).toBe(false);
  });

  it("rejects invalid product data", () => {
    expect(ProductSchema.safeParse({ externalId: "1" }).success).toBe(false);
  });
});

