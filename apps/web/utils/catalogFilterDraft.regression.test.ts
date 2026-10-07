import { describe, expect, it } from "vitest";
import { catalogFiltersEqual, compactCatalogFilters } from "./catalogFilterDraft";

describe("catalog filter draft regression cases", () => {
  it("preserves zero-valued filters while removing only empty selections", () => {
    expect(compactCatalogFilters({ price_min: "0", discount_min: "0", brands: "", sizes: "0,42" }))
      .toEqual({ price_min: "0", discount_min: "0", sizes: "0,42" });
  });

  it("keeps a multi-select draft distinct until all selected values match", () => {
    expect(catalogFiltersEqual(
      { brands: "Nike,Adidas", colors: "blue" },
      { brands: "Nike,Adidas", colors: "blue,black" }
    )).toBe(false);
  });

  it("treats equivalent draft objects as unchanged after compaction", () => {
    expect(catalogFiltersEqual(
      { price_min: "0", brands: "", colors: "blue,black" },
      { colors: "blue,black", price_min: "0" }
    )).toBe(true);
  });
});
