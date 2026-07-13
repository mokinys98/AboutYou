import { describe, expect, it } from "vitest";
import { inferFallbackCategories, inferFallbackCategoryPath, resolveFallbackCategory } from "./category-classifier";

describe("fallback product category classifier", () => {
  it.each([
    ["Sportbačiai be auliuko", "Batai"],
    ["Šlepetės per pirštą", "Batai"],
    ["Loaferai REGENT", "Batai"],
    ["Sandalai", "Batai"],
    ["Diržas JACHarry", "Aksesuarai"],
    ["Kepurė JACFRAME", "Aksesuarai"],
    ["Rankinė su ilgu dirželiu", "Aksesuarai"],
    ["Akiniai nuo saulės", "Aksesuarai"],
    ["Pirštuotos pirštinės", "Aksesuarai"]
  ])("classifies %s as %s", (name, category) => {
    expect(inferFallbackCategories(name)).toContain(category);
  });

  it("uses productTypes when the product name is not descriptive", () => {
    expect(inferFallbackCategories("JFWOLLIE", ["Šlepetės"])).toEqual(["Batai"]);
  });

  it("does not treat a shoe strap as a belt product", () => {
    expect(inferFallbackCategories("Batai su dirželiu")).toEqual(["Batai"]);
  });

  it("retains the existing clothing fallback", () => {
    expect(inferFallbackCategories("Ilga pižama")).toEqual(["Apatiniai"]);
  });

  it.each([
    ["Skrybėlaitė", ["Vyrams", "Aksesuarai", "Kepurės", "Skrybėlės"]],
    ["Megzta kepurė", ["Vyrams", "Aksesuarai", "Kepurės", "Megztos kepurės"]],
    ["Kuprinė", ["Vyrams", "Aksesuarai", "Krepšiai ir kuprinės", "Kuprinės"]],
    ["Analoginis laikrodis", ["Vyrams", "Aksesuarai", "Laikrodžiai"]],
    ["Apyrankė", ["Vyrams", "Aksesuarai", "Juvelyriniai dirbiniai", "Apyrankės"]],
    ["Šalikas", ["Vyrams", "Aksesuarai", "Šalikai ir šaliai"]],
    ["Sportbačiai be auliuko", ["Vyrams", "Batai", "Sportbačiai", "Sportbačiai žemu auliuku"]],
    ["Šlepetės", ["Vyrams", "Batai", "Atviri batai", "Šlepetės"]],
    ["Sportinės kojinės", ["Vyrams", "Drabužiai", "Apatiniai", "Kojinės"]]
  ])("builds a canonical fallback path for %s", (name, path) => {
    expect(inferFallbackCategoryPath(name)).toEqual(path);
  });
});

describe("resolveFallbackCategory", () => {
  it("prefers product metadata over a collection target label", () => {
    expect(resolveFallbackCategory("Sportbačiai COURT", ["Sportbačiai"], "Only Sons Katalogas")).toBe("Batai");
    expect(resolveFallbackCategory("Odinis diržas", ["Diržas"], "Only Sons Katalogas")).toBe("Aksesuarai");
  });

  it("accepts only canonical taxonomy labels as a target fallback", () => {
    expect(resolveFallbackCategory("Nežinomas produktas", [], "Batai")).toBe("Batai");
    expect(resolveFallbackCategory("Nežinomas produktas", [], "Only Sons Katalogas")).toBeUndefined();
  });
});
