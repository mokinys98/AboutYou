export function inferFallbackCategories(name: string, productTypes: readonly string[] = []): string[] {
  const value = [name, ...productTypes].join(" ").toLocaleLowerCase("lt");
  const rules: Array<[string, RegExp]> = [
    ["Batai", /batai|batų|sportbač|šlepet|loafer|sandal|aulin|espadril|mokasin|chukka|chelsea/],
    ["Aksesuarai", /(?:^|\s)dirž(?:as|ai)(?:$|\s)|kepur|rankin|akini|pirštin/],
    ["Marškinėliai", /marškinėl|polo|berankov/],
    ["Džinsai", /džins/],
    ["Apatiniai", /apatin|kojin|naktin|chalatas|trumpik|pižam/],
    ["Striukės", /striuk|parka|bomber|liemenė/],
    ["Marškiniai", /marškiniai/],
    ["Treningo dalys", /džemper|trening|sportinės kelnės/],
    ["Maudymosi drabužiai", /maudym|glaud/],
    ["Megztiniai", /megztin|kardigan/],
    ["Kostiumai ir švarkai", /kostium|švark/],
    ["Paltai", /palt|lietpalt/],
    ["Kelnės", /keln|šort/]
  ];
  return rules.filter(([, pattern]) => pattern.test(value)).map(([category]) => category).slice(0, 2);
}

const canonicalFallbackCategories = new Set([
  "drabužiai", "batai", "sportas", "aksesuarai", "streetwear", "premium",
  "marškinėliai", "kelnės", "apatiniai", "džinsai", "striukės", "marškiniai",
  "treningo dalys", "maudymosi drabužiai", "megztiniai", "kostiumai ir švarkai",
  "paltai", "proginiai", "išskirtiniai"
]);

/** Avoid turning a collection/brand target label into a catalog root. */
export function resolveFallbackCategory(
  name: string,
  productTypes: readonly string[] = [],
  targetLabel?: string
): string | undefined {
  const inferred = inferFallbackCategories(name, productTypes)[0];
  if (inferred) return inferred;
  const normalizedTarget = targetLabel?.replace(/\s+/g, " ").trim();
  return normalizedTarget && canonicalFallbackCategories.has(normalizedTarget.toLocaleLowerCase("lt"))
    ? normalizedTarget
    : undefined;
}
