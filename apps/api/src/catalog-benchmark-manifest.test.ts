/// <reference types="node" />

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseFilters } from "./index";

const manifest = JSON.parse(readFileSync(fileURLToPath(new URL(
  "../../../docs/katalogo-filtravimas/API_SCENARIJAI_2026-10-04.json",
  import.meta.url
)), "utf8")) as {
  groups: string[];
  scenarios: Array<{ id: string; group: string; query: string; cache_filters: Record<string, unknown> }>;
};

describe("catalog API benchmark manifest", () => {
  it("uses 40 distinct candidates per scenario group", () => {
    expect(manifest.scenarios).toHaveLength(240);
    for (const group of manifest.groups) {
      expect(manifest.scenarios.filter((scenario) => scenario.group === group)).toHaveLength(40);
    }
    expect(new Set(manifest.scenarios.map((scenario) => JSON.stringify(scenario.cache_filters))).size).toBe(240);
  });

  it("matches API parsing and exact DB cache filters", () => {
    for (const scenario of manifest.scenarios) {
      const parsed = parseFilters(Object.fromEntries(new URLSearchParams(scenario.query)));
      expect(parsed.success, scenario.id).toBe(true);
      if (!parsed.success) continue;
      const { sort: _sort, cursor: _cursor, limit: _limit, ...facetFilters } = parsed.data;
      const effectiveFacetFilters = {
        ...facetFilters,
        categories: facetFilters.categoryPath ? [facetFilters.categoryPath] : facetFilters.categories
      };
      expect(effectiveFacetFilters, scenario.id).toEqual(scenario.cache_filters);
    }
  });
});
