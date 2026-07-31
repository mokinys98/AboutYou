export function compactCatalogFilters(filters: Record<string, string>) {
  return Object.fromEntries(Object.entries(filters).filter(([, value]) => value !== ""));
}

export function catalogFiltersEqual(left: Record<string, string>, right: Record<string, string>) {
  const entries = (filters: Record<string, string>) => Object.entries(compactCatalogFilters(filters))
    .sort(([leftKey], [rightKey]) => leftKey.localeCompare(rightKey));

  return JSON.stringify(entries(left)) === JSON.stringify(entries(right));
}
