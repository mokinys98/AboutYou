import { describe, expect, it } from "vitest";
import { filterAlertPayload } from "./filterAlertPayload";

describe("filter alert payload conversion", () => {
  it("preserves zero-valued numeric filters", () => {
    expect(filterAlertPayload({ price_min: "0", price_max: "0", discount_min: "0", lpl_proximity_pct: "0" })).toMatchObject({
      priceMin: 0,
      priceMax: 0,
      discountMin: 0,
      lplProximityPct: 0,
    });
  });

  it("parses comma-decimal sizes and canonicalizes their domain token", () => {
    expect(filterAlertPayload({ sizes: "shoes:42%2C5,clothing:M" }).sizes).toEqual(["shoes:42.5", "clothing:m"]);
  });

  it("keeps legacy and other-size parsing behavior", () => {
    expect(filterAlertPayload({ sizes: "legacy-size,shoes:one_size", other_sizes: "XXL,one-size" })).toMatchObject({
      sizes: ["legacy-size", "shoes:one-size"],
      otherSizes: ["XXL", "one-size"],
    });
  });

  it("converts LPL percentage and price values using the existing units", () => {
    expect(filterAlertPayload({ lpl_proximity_pct: "12", price_min: "12.345", price_max: "99.99" })).toMatchObject({
      lplProximityPct: 12,
      priceMin: 1235,
      priceMax: 9999,
    });
  });

  it("maps boolean flags and comparison mode", () => {
    expect(filterAlertPayload({
      premium: "true",
      exclude_basics: "true",
      exclude_accessories: "true",
      below_observed_30d: "true",
      price_comparison: "source_lpl",
    })).toMatchObject({
      isPremium: true,
      excludeBasics: true,
      excludeAccessories: true,
      belowObserved30d: true,
      priceComparison: "source_lpl",
    });
    expect(filterAlertPayload({ premium: "false", price_comparison: "unexpected" })).toMatchObject({
      isPremium: false,
      priceComparison: "observed",
    });
  });
});
