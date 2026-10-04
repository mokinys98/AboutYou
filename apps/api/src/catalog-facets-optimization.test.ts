/// <reference types="node" />

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const migration = readFileSync(fileURLToPath(new URL(
  "../../../supabase/migrations/20261004100000_optimize_catalog_facet_prefilter.sql",
  import.meta.url
)), "utf8");

describe("catalog facet common-filter optimization", () => {
  it("filters common predicates before joining the expanded facet values", () => {
    const baseCte = migration.match(/base as materialized \(([\s\S]*?)\), facet_counts as materialized/);
    expect(baseCte).not.toBeNull();
    expect(baseCte?.[1]).toContain("where c.common_ok");
    expect(migration.indexOf("where c.common_ok")).toBeLessThan(
      migration.indexOf("join public.catalog_item_facet_values_read facet")
    );
    expect(baseCte?.[1]).not.toContain("(not common_ok)::integer");
  });

  it("retains per-facet self-exclusion and the existing response fields", () => {
    expect(migration).toContain("base.failed_groups - case facet.facet_group");
    expect(migration).toContain("when 'colorShades' then (not base.color_shade_ok)::integer");
    expect(migration).toContain("'colorShades'");
    expect(migration).toContain("'sizes'");
    expect(migration).toContain("'premium'");
    expect(migration).toContain("'price'");
  });
});
