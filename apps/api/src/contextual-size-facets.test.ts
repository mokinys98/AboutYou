/// <reference types="node" />

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migration = readFileSync(fileURLToPath(new URL(
  "../../../supabase/migrations/202607310001_restore_contextual_size_facets.sql",
  import.meta.url
)), "utf8");

describe("contextual size facet migration", () => {
  it("filters size membership by the requested category and other active filters", () => {
    expect(migration).toContain("catalog_build_contextual_size_facets");
    expect(migration).toContain("i.category_paths && f.categories");
    expect(migration).toContain("i.materials && f.materials");
    expect(migration).toContain("i.lpl_price_ratio <= 100 + f.lpl_proximity_pct");
    expect(migration).toContain("join public.catalog_size_facets_read_effective sf");
  });

  it("returns counts and caches the exact normalized filter context", () => {
    expect(migration).toContain("'count', grouped.product_count");
    expect(migration).toContain("public.catalog_grouped_size_facets(cache_filters)");
    expect(migration).toContain("where filters = cache_filters");
  });

  it("invalidates per-filter payloads when catalog membership changes", () => {
    expect(migration).toContain("delete from public.catalog_facets_cache;");
    expect(migration).toContain("perform public.invalidate_catalog_facets_cache();");
  });
});
