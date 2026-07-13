export function inferFallbackCategoryPath(name: string, productTypes: readonly string[] = []): string[] {
  const value = [name, ...productTypes].join(" ").toLocaleLowerCase("lt");
  const rules: Array<[string[], RegExp]> = [
    [["Vyrams", "Aksesuarai", "Akiniai nuo saulės"], /akiniai nuo saul/],
    [["Vyrams", "Aksesuarai", "Kepurės", "Megztos kepurės"], /megzta kepur/],
    [["Vyrams", "Aksesuarai", "Kepurės", "Skrybėlės"], /skrybėl/],
    [["Vyrams", "Aksesuarai", "Krepšiai ir kuprinės", "Kuprinės"], /kuprinė/],
    [["Vyrams", "Aksesuarai", "Piniginės ir kosmetinės"], /tualeto reikmenų|kosmetikos krepš/],
    [["Vyrams", "Aksesuarai", "Krepšiai ir kuprinės", "Krepšiai"], /pirkinių krepš|sportinis krepš|krepšys|rankinė/],
    [["Vyrams", "Aksesuarai", "Laikrodžiai"], /laikrodis/],
    [["Vyrams", "Aksesuarai", "Juvelyriniai dirbiniai", "Apyrankės"], /apyrank/],
    [["Vyrams", "Aksesuarai", "Juvelyriniai dirbiniai", "Grandinėlės"], /grandinėl/],
    [["Vyrams", "Aksesuarai", "Juvelyriniai dirbiniai"], /auskar|žiedas/],
    [["Vyrams", "Aksesuarai", "Šalikai ir šaliai"], /šalik|skara/],
    [["Vyrams", "Aksesuarai"], /raktų laikikl/],
    [["Vyrams", "Batai", "Sportbačiai", "Sportbačiai žemu auliuku"], /sportbačiai be auliuko/],
    [["Vyrams", "Batai", "Atviri batai", "Šlepetės"], /šlepet/],
    [["Vyrams", "Batai", "Batai ir auliniai batai", "Auliniai batai"], /auliniai batai/],
    [["Vyrams", "Drabužiai", "Apatiniai", "Kojinės"], /sportinės kojinės|kojinės/],
    [["Vyrams", "Batai"], /batai|batų|sportbač|loafer|sandal|aulin|espadril|mokasin|chukka|chelsea/],
    [["Vyrams", "Aksesuarai"], /(?:^|\s)dirž(?:as|ai)(?:$|\s)|kepur|rankin|akini|pirštin/],
    [["Vyrams", "Drabužiai", "Marškinėliai"], /marškinėl|polo|berankov/],
    [["Vyrams", "Drabužiai", "Džinsai"], /džins/],
    [["Vyrams", "Drabužiai", "Apatiniai"], /apatin|naktin|chalatas|trumpik|pižam/],
    [["Vyrams", "Drabužiai", "Striukės"], /striuk|parka|bomber|liemenė/],
    [["Vyrams", "Drabužiai", "Marškiniai"], /marškiniai/],
    [["Vyrams", "Drabužiai", "Treningo dalys"], /džemper|trening|sportinės kelnės/],
    [["Vyrams", "Drabužiai", "Maudymosi drabužiai"], /maudym|glaud/],
    [["Vyrams", "Drabužiai", "Megztiniai"], /megztin|kardigan/],
    [["Vyrams", "Drabužiai", "Kostiumai ir švarkai"], /kostium|švark/],
    [["Vyrams", "Drabužiai", "Paltai"], /palt|lietpalt/],
    [["Vyrams", "Drabužiai", "Kelnės"], /keln|šort/]
  ];
  return rules.find(([, pattern]) => pattern.test(value))?.[0] ?? [];
}

export function inferFallbackCategories(name: string, productTypes: readonly string[] = []): string[] {
  const path = inferFallbackCategoryPath(name, productTypes);
  if (!path.length) return [];
  return [path[1] === "Drabužiai" ? path[2] : path[1]].filter((value): value is string => Boolean(value));
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
