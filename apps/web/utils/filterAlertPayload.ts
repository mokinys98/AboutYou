import {
  canonicalCatalogSizeToken,
  parseCatalogSizeFilters,
  type CatalogAlertFilters,
} from "@catalog/shared";

/** Converts URL-style catalog filter values into the alert API filter shape. */
export function filterAlertPayload(filters: Record<string, string>): Partial<CatalogAlertFilters> {
  const list = (key: string) => filters[key]?.split(",").map((value) => value.trim()).filter(Boolean) ?? [];

  return {
    brands: list("brands"), brandTiers: list("brand_tiers") as CatalogAlertFilters["brandTiers"], sources: list("sources"),
    categories: list("categories"), categoryPath: filters.category || undefined,
    colors: list("colors") as CatalogAlertFilters["colors"], colorShades: list("color_shades") as CatalogAlertFilters["colorShades"],
    sizes: parseCatalogSizeFilters(filters.sizes).map(canonicalCatalogSizeToken), otherSizes: parseCatalogSizeFilters(filters.other_sizes), materials: list("materials"), patterns: list("patterns"),
    features: list("features"), styles: list("styles"), productTypes: list("product_types"),
    isPremium: filters.premium === "true", excludeBasics: filters.exclude_basics === "true",
    excludeAccessories: filters.exclude_accessories === "true",
    priceMin: filters.price_min ? Math.round(Number(filters.price_min) * 100) : undefined,
    priceMax: filters.price_max ? Math.round(Number(filters.price_max) * 100) : undefined,
    discountMin: filters.discount_min ? Number(filters.discount_min) : undefined,
    lplProximityPct: filters.lpl_proximity_pct ? Number(filters.lpl_proximity_pct) : undefined,
    belowObserved30d: filters.below_observed_30d === "true",
    priceComparison: filters.price_comparison === "source_lpl" ? "source_lpl" : "observed"
  };
}
