import { describe, expect, it } from "vitest";
import { inferFallbackCategories } from "./category-classifier";

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
});
