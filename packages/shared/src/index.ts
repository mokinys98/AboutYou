import { z } from "zod";

export const colorFamilies = [
  "black", "white", "grey", "brown", "beige", "red", "orange", "yellow",
  "green", "blue", "purple", "pink", "silver", "gold", "multicolor", "other"
] as const;

export const ColorFamilySchema = z.enum(colorFamilies);
export type ColorFamily = z.infer<typeof ColorFamilySchema>;

export const colorShades = [
  "black", "white", "off_white", "cream", "beige", "taupe", "grey", "charcoal",
  "brown", "camel", "copper", "rust", "red", "burgundy", "orange", "yellow",
  "mustard", "green", "olive", "khaki", "mint", "teal", "turquoise", "blue",
  "navy", "purple", "lilac", "pink", "rose", "silver", "gold", "multicolor", "other"
] as const;

export const ColorShadeSchema = z.enum(colorShades);
export type ColorShade = z.infer<typeof ColorShadeSchema>;

export const colorShadeLabels: Record<ColorShade, string> = Object.fromEntries(
  colorShades.map((shade) => [shade, shade === "off_white" ? "Off White" : shade.replace(/_/g, " ").replace(/^./, (letter) => letter.toUpperCase())])
) as Record<ColorShade, string>;

const AttributeValuesSchema = z.array(z.string().trim().min(1)).default([]);

export const ProductSchema = z.object({
  externalId: z.string().min(1),
  name: z.string().min(1),
  brand: z.string().default(""),
  productUrl: z.string().url(),
  imageUrls: z.array(z.string().url()).default([]),
  colorOriginal: z.string().nullable().default(null),
  colorFamily: ColorFamilySchema.default("other"),
  colorShade: ColorShadeSchema.default("other"),
  categories: z.array(z.string()).default([]),
  categoryPath: z.array(z.string()).default([]),
  sizes: AttributeValuesSchema,
  otherSizes: AttributeValuesSchema,
  materials: AttributeValuesSchema,
  patterns: AttributeValuesSchema,
  features: AttributeValuesSchema,
  styles: AttributeValuesSchema,
  productTypes: AttributeValuesSchema,
  currentPrice: z.number().int().nonnegative(),
  originalPrice: z.number().int().nonnegative().nullable().default(null),
  sourceLpl30: z.number().int().nonnegative().nullable().default(null),
  currency: z.string().length(3).default("EUR")
});
export type Product = z.infer<typeof ProductSchema>;

export const SyncTargetKindSchema = z.enum(["category", "brand", "search"]);
export const SyncTargetSchema = z.object({
  id: z.string().uuid(),
  sourceId: z.string().uuid(),
  kind: SyncTargetKindSchema,
  label: z.string().min(1),
  url: z.string().url(),
  enabled: z.boolean(),
  priority: z.number().int(),
  requestedAt: z.string().datetime().nullable().optional(),
  lastSuccessAt: z.string().datetime().nullable().optional()
});
export type SyncTarget = z.infer<typeof SyncTargetSchema>;

export const CatalogSortSchema = z.enum(["price_asc", "price_desc", "discount_desc", "newest", "first_seen"]);
export const PriceComparisonSchema = z.enum(["observed", "source_lpl"]);
export const CatalogFiltersSchema = z.object({
  brands: z.array(z.string()).default([]),
  sources: z.array(z.string()).default([]),
  categories: z.array(z.string()).default([]),
  categoryPath: z.string().trim().min(1).optional(),
  colors: z.array(ColorFamilySchema).default([]),
  colorShades: z.array(ColorShadeSchema).default([]),
  sizes: z.array(z.string()).default([]),
  otherSizes: z.array(z.string()).default([]),
  materials: z.array(z.string()).default([]),
  patterns: z.array(z.string()).default([]),
  features: z.array(z.string()).default([]),
  styles: z.array(z.string()).default([]),
  productTypes: z.array(z.string()).default([]),
  priceMin: z.number().int().nonnegative().optional(),
  priceMax: z.number().int().nonnegative().optional(),
  discountMin: z.number().min(0).max(100).optional(),
  belowObserved30d: z.boolean().default(false),
  newOnly: z.boolean().default(false),
  priceComparison: PriceComparisonSchema.default("observed"),
  sort: CatalogSortSchema.default("newest"),
  cursor: z.string().optional(),
  limit: z.number().int().min(1).max(100).default(48)
});
export type CatalogFilters = z.infer<typeof CatalogFiltersSchema>;

export const CatalogItemSchema = z.object({
  id: z.string().uuid(),
  externalId: z.string(),
  name: z.string(),
  brand: z.string(),
  productUrl: z.string().url(),
  imageUrls: z.array(z.string()),
  colorOriginal: z.string().nullable(),
  colorFamily: ColorFamilySchema,
  colorShade: ColorShadeSchema,
  categories: z.array(z.string()),
  categoryPaths: z.array(z.string()).default([]),
  sizes: z.array(z.string()).default([]),
  otherSizes: z.array(z.string()).default([]),
  materials: z.array(z.string()).default([]),
  patterns: z.array(z.string()).default([]),
  features: z.array(z.string()).default([]),
  styles: z.array(z.string()).default([]),
  productTypes: z.array(z.string()).default([]),
  source: z.string(),
  currentPrice: z.number().int(),
  originalPrice: z.number().int().nullable(),
  sourceLpl30: z.number().int().nullable(),
  observedMin30d: z.number().int().nullable(),
  discountPct: z.number().nonnegative(),
  currency: z.string(),
  updatedAt: z.string(),
  firstSeenAt: z.string(),
  isWatched: z.boolean().default(false)
});
export type CatalogItem = z.infer<typeof CatalogItemSchema>;

export const ProductDetailStatusSchema = z.enum([
  "complete", "pending", "retryable_error", "blocked_schema", "source_unavailable"
]);
export const ProductDetailSectionKeySchema = z.enum([
  "size_and_fit", "measurements", "material_composition", "design_and_extras"
]);
export type ProductDetailSectionKey = z.infer<typeof ProductDetailSectionKeySchema>;
export const ProductDetailItemSchema = z.object({
  label: z.string().nullable(),
  value: z.string(),
  unit: z.string().nullable(),
  rawText: z.string()
});
export const ProductDetailSectionSchema = z.object({
  key: ProductDetailSectionKeySchema,
  sourceLabel: z.string(),
  status: z.enum(["present", "source_absent"]),
  items: z.array(ProductDetailItemSchema)
});
export const ProductColorOptionSchema = z.object({
  externalId: z.string().nullable(),
  label: z.string(),
  url: z.string().url().nullable(),
  selected: z.boolean()
});
export const ProductSizeOptionSchema = z.object({
  externalId: z.string(),
  label: z.string(),
  group: z.string().nullable(),
  selected: z.boolean(),
  selectable: z.boolean(),
  availability: z.string().nullable()
});
export const ProductDetailSchema = z.object({
  status: ProductDetailStatusSchema,
  parserVersion: z.number().int().nonnegative(),
  staticSyncedAt: z.string().nullable(),
  availabilitySyncedAt: z.string().nullable(),
  sections: z.array(ProductDetailSectionSchema),
  colorOptions: z.array(ProductColorOptionSchema),
  sizeOptions: z.array(ProductSizeOptionSchema)
});
export type ProductDetail = z.infer<typeof ProductDetailSchema>;

export const ProductDetailResponseSchema = CatalogItemSchema.extend({
  detail: ProductDetailSchema,
  history: z.array(z.object({
    observed_date: z.string(), min_price: z.number().int(), max_price: z.number().int(),
    last_price: z.number().int(), source_lpl_30: z.number().int().nullable()
  })),
  priceChanges: z.array(z.object({
    observed_at: z.string(), price: z.number().int(), original_price: z.number().int().nullable(),
    source_lpl_30: z.number().int().nullable()
  }))
});
export type ProductDetailResponse = z.infer<typeof ProductDetailResponseSchema>;

export interface CatalogResponse {
  items: CatalogItem[];
  nextCursor: string | null;
  totalCount?: number;
}

export interface CatalogFacets {
  brands: Array<{ value: string; count: number }>;
  categories: CatalogCategoryFacet[];
  colors: Array<{ value: ColorFamily; count: number }>;
  colorShades: Array<{ value: ColorShade; count: number }>;
  sources: Array<{ value: string; count: number }>;
  sizes: Array<{ value: string; count: number }>;
  otherSizes: Array<{ value: string; count: number }>;
  materials: Array<{ value: string; count: number }>;
  patterns: Array<{ value: string; count: number }>;
  features: Array<{ value: string; count: number }>;
  styles: Array<{ value: string; count: number }>;
  productTypes: Array<{ value: string; count: number }>;
  price: { min: number; max: number };
}

export interface CatalogCategoryFacet {
  id: string;
  parentId: string | null;
  name: string;
  level: number;
  path: string;
  count: number;
}

export interface CatalogCategoryNode extends CatalogCategoryFacet {
  children: CatalogCategoryNode[];
}

const categoryRootPriority = new Map([
  ["drabužiai", 0], ["batai", 1], ["sportas", 2], ["aksesuarai", 3], ["streetwear", 4]
]);

export function normalizeCategoryPath(values: readonly string[], fallbackRoot?: string): string[] {
  const cleaned = values
    .map((value) => value.replace(/\s+/g, " ").trim())
    .filter(Boolean);
  const genderIndex = cleaned.findIndex((value) => value.toLocaleLowerCase("lt") === "vyrams");
  const source = genderIndex >= 0 ? cleaned.slice(genderIndex + 1) : cleaned;
  const first = source[0]?.toLocaleLowerCase("lt");
  const clothingParent = clothingCategoryTree.find((category) =>
    category.name.toLocaleLowerCase("lt") === first ||
    category.children.some((child) => child.toLocaleLowerCase("lt") === first)
  );
  if (clothingParent && first !== "drabužiai") {
    if (clothingParent.name.toLocaleLowerCase("lt") !== first) source.unshift(clothingParent.name);
    source.unshift("Drabužiai");
  }
  let fallback = fallbackRoot?.replace(/\s+/g, " ").trim();
  if (clothingParent) fallback = undefined;
  const fallbackClothingParent = clothingCategoryTree.find((category) =>
    category.name.toLocaleLowerCase("lt") === fallback?.toLocaleLowerCase("lt")
  );
  if (!clothingParent && fallbackClothingParent) {
    if (source[0]?.toLocaleLowerCase("lt") !== fallback?.toLocaleLowerCase("lt")) source.unshift(fallbackClothingParent.name);
    source.unshift("Drabužiai");
    fallback = undefined;
  }
  const path = ["Vyrams"];
  if (fallback && source[0]?.toLocaleLowerCase("lt") !== fallback.toLocaleLowerCase("lt")) path.push(fallback);
  for (const value of source) {
    if (path.at(-1)?.toLocaleLowerCase("lt") !== value.toLocaleLowerCase("lt")) path.push(value);
  }
  return path.slice(0, 4);
}

export function buildCategoryTree(items: readonly CatalogCategoryFacet[]): CatalogCategoryNode[] {
  const nodes = new Map(items.map((item) => [item.id, { ...item, children: [] as CatalogCategoryNode[] }]));
  const roots: CatalogCategoryNode[] = [];
  for (const node of nodes.values()) {
    const parent = node.parentId ? nodes.get(node.parentId) : undefined;
    if (parent) parent.children.push(node);
    else if (node.level === 2) roots.push(node);
  }
  const compare = (left: CatalogCategoryNode, right: CatalogCategoryNode) => {
    if (left.level === 2 && right.level === 2) {
      const priority = (categoryRootPriority.get(left.name.toLocaleLowerCase("lt")) ?? 99) -
        (categoryRootPriority.get(right.name.toLocaleLowerCase("lt")) ?? 99);
      if (priority) return priority;
    }
    return left.name.localeCompare(right.name, "lt");
  };
  const sort = (values: CatalogCategoryNode[]) => {
    values.sort(compare);
    values.forEach((value) => sort(value.children));
  };
  sort(roots);
  return roots;
}

export const clothingCategoryTree = [
  { name: "Marškinėliai", children: ["Polo marškinėliai", "Laisvalaikio marškinėliai", "Marškinėlių komplektai", "Berankoviai marškinėliai", "Marškinėliai ilgomis rankovėmis"] },
  { name: "Kelnės", children: ["Šortai", "„Chino“ stiliaus kelnės", "Sportinės kelnės", "Kasdienės kelnės", "„Cargo“ stiliaus kelnės"] },
  { name: "Apatiniai", children: ["Apatinės kelnės", "Kojinės", "Apatiniai marškinėliai", "Naktiniai drabužiai", "Vonios chalatai"] },
  { name: "Džinsai", children: ["Džinsiniai šortai", "Tiesūs džinsai", "Siauri prigludę džinsai", "Laisvo kirpimo džinsai", "Siauri džinsai", "Siaurėjantys džinsai"] },
  { name: "Striukės", children: ["Odinės striukės", "Liemenės", "Džinsiniai švarkeliai ir striukės", "Demisezoninės striukės", "Žieminės striukės", "Dygsniuotos striukės", "„Bomber“ stiliaus striukės", "Parka striukės", "Laisvalaikio striukės", "Striukės nuo lietaus", "Pūkinės striukės"] },
  { name: "Marškiniai", children: ["Kasdieniniai marškiniai", "Dalykinio stiliaus marškiniai", "Džinsiniai marškiniai", "Flaneliniai marškiniai"] },
  { name: "Treningo dalys", children: ["Sportinės kelnės", "Džemperiai be kapišono", "Džemperiai su kapišonu", "Džemperiai su kapišonu ir užtrauktuku", "Džemperiai su užtrauktuku", "Flisiniai džemperiai"] },
  { name: "Maudymosi drabužiai", children: ["Maudymosi šortai", "Glaudės"] },
  { name: "Megztiniai", children: ["Įvairūs megztiniai", "Kardiganai"] },
  { name: "Kostiumai ir švarkai", children: ["Kostiumai", "Švarkai", "Kostiuminės kelnės", "Kostiuminiai švarkai", "Dalykinio stiliaus liemenės"] },
  { name: "Paltai", children: ["Žieminiai paltai", "Demisezoniniai paltai", "Vilnoniai paltai", "Trumpi paltai", "Lietpalčiai"] },
  { name: "Proginiai", children: ["Biuro apranga", "Vestuvės", "Kalėdoms"] },
  { name: "Išskirtiniai", children: ["Marškiniai ir marškinėliai", "Džinsai ir kelnės", "Švarkai ir paltai", "Apatiniai drabužiai ir maudymosi drabužiai", "Megztiniai ir džemperiai"] }
] as const;

export const clothingCategories = clothingCategoryTree.map((category) => category.name);

/** Top-level catalog sections that are shown when at least one active product uses them. */
export const catalogRootCategories = [
  "Batai",
  "Sportas",
  "Aksesuarai",
  "Streetwear"
] as const;

export function expandClothingCategoryPath(values: readonly string[]): string[] {
  const normalized = new Map<string, string>();
  for (const value of values) {
    const name = value.replace(/\s+/g, " ").trim();
    if (name) normalized.set(name.toLocaleLowerCase("lt"), name);
  }

  const result = new Set<string>();
  const add = (value: string) => result.add(value);
  const hasExplicitParent = clothingCategoryTree.some((category) =>
    normalized.has(category.name.toLocaleLowerCase("lt"))
  );
  for (const category of clothingCategoryTree) {
    const parentSelected = normalized.has(category.name.toLocaleLowerCase("lt"));
    if (hasExplicitParent && !parentSelected) continue;
    const selectedChildren = category.children.filter((child) => normalized.has(child.toLocaleLowerCase("lt")));
    if (!parentSelected && selectedChildren.length === 0) continue;
    add("Drabužiai");
    add(category.name);
    selectedChildren.forEach(add);
  }

  for (const [key, value] of normalized) {
    if (key === "vyrams") continue;
    if (![...result].some((item) => item.toLocaleLowerCase("lt") === key)) add(value);
  }
  return [...result];
}

export function cents(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return Math.round(value);
  if (typeof value !== "string") return null;
  const normalized = value.replace(/<[^>]*>/g, " ").replace(/\u00a0/g, " ");
  const match = normalized.match(/(\d{1,4}(?:[ .]\d{3})*|\d+)(?:[,.](\d{1,2}))?\s*€/);
  if (!match) return null;
  const euros = Number((match[1] ?? "").replace(/[ .]/g, ""));
  const fraction = Number((match[2] ?? "00").padEnd(2, "0").slice(0, 2));
  return Number.isFinite(euros) ? euros * 100 + fraction : null;
}

export function normalizeColor(value: string | null | undefined): ColorFamily {
  const color = (value ?? "").toLocaleLowerCase("lt").trim();
  const aliases: Array<[ColorFamily, RegExp]> = [
    ["black", /juod|black|schwarz/], ["white", /balt|white|weiß|weiss/],
    ["grey", /pilk|grey|gray|grau|charcoal|antracit/], ["orange", /oran|orange|rust|rūdžių|rudziu/],
    ["brown", /rud|brown|braun|copper|vario|camel|taupe/],
    ["beige", /smė|smel|beige|cream|kremin/], ["red", /raud|red|rot|burgund|bordo/],
    ["yellow", /gelton|yellow|gelb|mustard|garsty/],
    ["green", /žal|zal|green|grün|grun|olive|alyvuog|khaki|chaki|mint|teal|petrol/], ["blue", /mėlyn|melyn|blue|navy|marine|blau|turquoise|turkio/],
    ["purple", /violet|purple|lila|lilac|alyvin/], ["pink", /rož|roz|pink|rosa|rose/],
    ["silver", /sidabr|silver|silber/], ["gold", /auks|gold/],
    ["multicolor", /multi|įvair|ivair|spalvot|bunt/]
  ];
  return aliases.find(([, pattern]) => pattern.test(color))?.[0] ?? "other";
}

export function normalizeColorShade(value: string | null | undefined): ColorShade {
  const color = (value ?? "").toLocaleLowerCase("lt").trim();
  const aliases: Array<[ColorShade, RegExp]> = [
    ["off_white", /off[ -]?white|balta su|ne visai balta/],
    ["charcoal", /charcoal|antracit/], ["burgundy", /burgund|bordo|vyno raud/],
    ["turquoise", /turkio|turquoise|türkis/], ["copper", /vario|copper|kupfer/],
    ["rust", /rūdžių|rudziu|rust|rost/], ["mustard", /garsty|mustard|senf/],
    ["olive", /alyvuog|olive|oliv/], ["khaki", /chaki|khaki/],
    ["teal", /teal|žalsvai mėl|zalsvai mel|petrol/], ["mint", /mėt|metų|mint/],
    ["navy", /tamsiai mėl|tamsiai mel|navy|marine/], ["lilac", /alyvin|lilac|lila/],
    ["rose", /rožinio aukso|rose gold|dusty rose|sendinta rož/],
    ["cream", /kremin|cream|ivory|dramblio kaulo/], ["taupe", /taupe|pilkai rud/],
    ["camel", /camel|kupranug/], ["beige", /smė|smel|beige/],
    ["black", /juod|black|schwarz/], ["white", /balt|white|weiß|weiss/],
    ["grey", /pilk|grey|gray|grau/], ["brown", /rud|brown|braun/],
    ["red", /raud|red|rot/], ["orange", /oran|orange/],
    ["yellow", /gelton|yellow|gelb/], ["green", /žal|zal|green|grün|grun/],
    ["blue", /mėlyn|melyn|blue|blau/], ["purple", /violet|purple/],
    ["pink", /rož|roz|pink|rosa/], ["silver", /sidabr|silver|silber/],
    ["gold", /auks|gold/], ["multicolor", /multi|įvair|ivair|spalvot|bunt/]
  ];
  return aliases.find(([, pattern]) => pattern.test(color))?.[0] ?? "other";
}

export function isAllowedAboutYouUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && (url.hostname === "aboutyou.lt" || url.hostname.endsWith(".aboutyou.lt"));
  } catch {
    return false;
  }
}
