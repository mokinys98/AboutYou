import { z } from "zod";

export const colorFamilies = [
  "black", "white", "grey", "brown", "beige", "red", "orange", "yellow",
  "green", "blue", "purple", "pink", "silver", "gold", "multicolor", "other"
] as const;

export const ColorFamilySchema = z.enum(colorFamilies);
export type ColorFamily = z.infer<typeof ColorFamilySchema>;

export const ProductSchema = z.object({
  externalId: z.string().min(1),
  name: z.string().min(1),
  brand: z.string().default(""),
  productUrl: z.string().url(),
  imageUrls: z.array(z.string().url()).default([]),
  colorOriginal: z.string().nullable().default(null),
  colorFamily: ColorFamilySchema.default("other"),
  categories: z.array(z.string()).default([]),
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
export const CatalogFiltersSchema = z.object({
  brands: z.array(z.string()).default([]),
  sources: z.array(z.string()).default([]),
  categories: z.array(z.string()).default([]),
  colors: z.array(ColorFamilySchema).default([]),
  priceMin: z.number().int().nonnegative().optional(),
  priceMax: z.number().int().nonnegative().optional(),
  discountMin: z.number().min(0).max(100).optional(),
  belowObserved30d: z.boolean().default(false),
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
  categories: z.array(z.string()),
  source: z.string(),
  currentPrice: z.number().int(),
  originalPrice: z.number().int().nullable(),
  sourceLpl30: z.number().int().nullable(),
  observedMin30d: z.number().int().nullable(),
  currency: z.string(),
  updatedAt: z.string()
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
  sources: Array<{ value: string; count: number }>;
  price: { min: number; max: number };
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
    ["grey", /pilk|grey|gray|grau/], ["brown", /rud|brown|braun/],
    ["beige", /smė|smel|beige|cream|kremin/], ["red", /raud|red|rot/],
    ["orange", /oran|orange/], ["yellow", /gelton|yellow|gelb/],
    ["green", /žal|zal|green|grün|grun/], ["blue", /mėlyn|melyn|blue|navy|marine|blau/],
    ["purple", /violet|purple|lila/], ["pink", /rož|roz|pink|rosa/],
    ["silver", /sidabr|silver|silber/], ["gold", /auks|gold/],
    ["multicolor", /multi|įvair|ivair|spalvot|bunt/]
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

