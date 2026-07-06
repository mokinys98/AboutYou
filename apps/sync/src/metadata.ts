import { chromium } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { enrichMissingProductMetadata } from "@catalog/aboutyou-provider";
import { expandClothingCategoryPath, type Product } from "@catalog/shared";
import { inferFallbackCategories } from "./category-classifier";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  METADATA_SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(50_000).default(10_000),
  METADATA_SYNC_CONCURRENCY: z.coerce.number().int().min(1).max(12).default(3),
  METADATA_SYNC_DELAY_MS: z.coerce.number().int().min(250).max(60_000).default(250),
  SYNC_HEADLESS: z.string().default("true").transform((value) => value !== "false")
});

const env = EnvSchema.parse(process.env);
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const startedAt = Date.now();
log(`Metaduomenų sync pradėtas (maxProducts=${env.METADATA_SYNC_MAX_PRODUCTS}).`);
const products = await loadActiveProducts();
log(`Rasta ${products.length} aktyvių produktų; kiekvienas bus aplankytas vieną kartą.`);

const browser = await chromium.launch({ headless: env.SYNC_HEADLESS });
let attempted = 0;
let refreshed = 0;
try {
  const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  const page = await context.newPage();
  for (const sourceProducts of groupBySource(products).values()) {
    const sourceByExternalId = new Map(sourceProducts.map((row) => [row.external_id, row]));
    const result = await enrichMissingProductMetadata(page, sourceProducts.map(toProduct), {
      limit: sourceProducts.length,
      onlyMissing: false,
      failOnRateLimit: true,
      concurrency: env.METADATA_SYNC_CONCURRENCY,
      delayMs: env.METADATA_SYNC_DELAY_MS,
      onProgress: ({ processed, total, foundColors, foundCategories }) =>
        log(`Apdorota ${attempted + processed}/${products.length}; naujų spalvų ${foundColors}, kategorijų kelių ${foundCategories} (${processed}/${total} šaltinyje).`)
    });
    attempted += result.attempted;
    const refreshedIds = new Set(result.refreshedExternalIds);
    const updates = result.products.flatMap((product) => {
      if (!refreshedIds.has(product.externalId)) return [];
      const row = sourceByExternalId.get(product.externalId);
      if (!row) return [];
      const exactCategories = expandClothingCategoryPath(product.categories);
      return [{
        id: row.id,
        colorOriginal: product.colorOriginal,
        colorFamily: product.colorFamily,
        categories: exactCategories.length ? exactCategories : inferFallbackCategories(product.name, product.productTypes),
        categoriesExact: exactCategories.length > 0,
        sizes: product.sizes,
        otherSizes: product.otherSizes,
        materials: product.materials,
        patterns: product.patterns,
        features: product.features,
        styles: product.styles,
        productTypes: product.productTypes
      }];
    });
    for (const batch of chunks(updates, 200)) {
      const { data, error } = await db.rpc("record_product_metadata_batch", { p_products: batch });
      if (error) throw error;
      refreshed += Number(data ?? batch.length);
    }
  }
  await context.close();
} finally {
  await browser.close();
}

log(`Metaduomenų sync baigtas: aplankyta ${attempted}, su metaduomenimis ${refreshed}, trukmė ${formatDuration(Date.now() - startedAt)}.`);

type ProductRow = {
  id: string;
  source_id: string;
  external_id: string;
  name: string;
  brand: string;
  product_url: string;
  image_urls: string[];
  color_original: string | null;
  color_family: Product["colorFamily"];
  color_shade: Product["colorShade"];
  sizes: string[];
  other_sizes: string[];
  materials: string[];
  patterns: string[];
  features: string[];
  styles: string[];
  product_types: string[];
};

async function loadActiveProducts(): Promise<ProductRow[]> {
  const pageSize = 1_000;
  const rows: ProductRow[] = [];
  for (let from = 0; from < env.METADATA_SYNC_MAX_PRODUCTS; from += pageSize) {
    const to = Math.min(from + pageSize, env.METADATA_SYNC_MAX_PRODUCTS) - 1;
    const { data, error } = await db.from("products")
      .select("id,source_id,external_id,name,brand,product_url,image_urls,color_original,color_family,color_shade,sizes,other_sizes,materials,patterns,features,styles,product_types")
      .eq("active", true).order("id").range(from, to);
    if (error) throw error;
    rows.push(...(data as ProductRow[] ?? []));
    if ((data?.length ?? 0) < to - from + 1) break;
  }
  return rows;
}

function toProduct(row: ProductRow): Product {
  return {
    externalId: row.external_id, name: row.name, brand: row.brand, productUrl: row.product_url,
    imageUrls: row.image_urls ?? [], colorOriginal: row.color_original, colorFamily: row.color_family,
    colorShade: row.color_shade, categories: [], sizes: row.sizes ?? [], otherSizes: row.other_sizes ?? [],
    materials: row.materials ?? [], patterns: row.patterns ?? [], features: row.features ?? [],
    styles: row.styles ?? [], productTypes: row.product_types ?? [], currentPrice: 0, originalPrice: null,
    sourceLpl30: null, currency: "EUR"
  };
}

function groupBySource(rows: ProductRow[]): Map<string, ProductRow[]> {
  const groups = new Map<string, ProductRow[]>();
  for (const row of rows) groups.set(row.source_id, [...(groups.get(row.source_id) ?? []), row]);
  return groups;
}

function chunks<T>(items: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let index = 0; index < items.length; index += size) result.push(items.slice(index, index + size));
  return result;
}

function log(message: string): void { console.log(`[metadata-sync ${new Date().toISOString()}] ${message}`); }
function formatDuration(milliseconds: number): string {
  const seconds = Math.max(0, Math.round(milliseconds / 1_000));
  return seconds < 60 ? `${seconds} s` : `${Math.floor(seconds / 60)} min ${seconds % 60} s`;
}
