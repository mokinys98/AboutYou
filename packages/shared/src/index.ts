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

export const CatalogSortSchema = z.enum(["price_asc", "price_desc", "discount_desc", "newest"]);
export const PriceComparisonSchema = z.enum(["observed", "source_lpl"]);
export const CatalogFiltersSchema = z.object({
  brands: z.array(z.string()).default([]),
  sources: z.array(z.string()).default([]),
  categories: z.array(z.string()).default([]),
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
  currency: z.string(),
  updatedAt: z.string(),
  isWatched: z.boolean().default(false)
});
export type CatalogItem = z.infer<typeof CatalogItemSchema>;

export interface CatalogResponse {
  items: CatalogItem[];
  nextCursor: string | null;
}

export interface CatalogFacets {
  brands: Array<{ value: string; count: number }>;
  categories: Array<{ value: string; count: number }>;
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
