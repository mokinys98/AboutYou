import { describe, expect, it } from "vitest";
import { catalogFiltersEqual, compactCatalogFilters } from "./catalogFilterDraft";

describe("catalog filter draft", () => {
  it("removes empty values before applying a draft", () => {
    expect(compactCatalogFilters({ colors: "blue,black", brands: "", sort: "newest" }))
      .toEqual({ colors: "blue,black", sort: "newest" });
  });

  it("compares filters independently of object key order", () => {
    expect(catalogFiltersEqual(
      { colors: "blue,black", category: "men>jeans" },
      { category: "men>jeans", colors: "blue,black" }
    )).toBe(true);
  });

  it("detects an unapplied multi-select change", () => {
    expect(catalogFiltersEqual(
      { color_shades: "blue" },
      { color_shades: "blue,navy" }
    )).toBe(false);
  });
});
