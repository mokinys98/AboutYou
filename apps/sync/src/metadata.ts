import { chromium } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { AboutYouRateLimitError, enrichMissingProductMetadata } from "@catalog/aboutyou-provider";
import { normalizeCategoryPath, type Product } from "@catalog/shared";
import { inferFallbackCategories } from "./category-classifier";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  METADATA_SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(50_000).default(500),
  METADATA_SYNC_CONCURRENCY: z.coerce.number().int().min(1).max(12).default(3),
  METADATA_SYNC_DELAY_MS: z.coerce.number().int().min(250).max(60_000).default(750),
  SYNC_HEADLESS: z.string().default("true").transform((value) => value !== "false")
});

const env = EnvSchema.parse(process.env);
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const startedAt = Date.now();
log(`Metaduomenų sync pradėtas (maxProducts=${env.METADATA_SYNC_MAX_PRODUCTS}).`);
const products = await loadActiveProducts();
log(`Rasta ${products.length} aktyvių produktų, kurių detalūs metaduomenys dar nepatikrinti.`);

const browser = await chromium.launch({ headless: env.SYNC_HEADLESS });
let attempted = 0;
let refreshed = 0;
try {
  const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  const page = await context.newPage();
  try {
    for (const sourceProducts of groupBySource(products).values()) {
      for (const productBatch of chunks(sourceProducts, 25)) {
        const sourceByExternalId = new Map(productBatch.map((row) => [row.external_id, row]));
        const result = await enrichMissingProductMetadata(page, productBatch.map(toProduct), {
          limit: productBatch.length,
          onlyMissing: false,
          failOnRateLimit: true,
          concurrency: env.METADATA_SYNC_CONCURRENCY,
          delayMs: env.METADATA_SYNC_DELAY_MS
        });
        attempted += result.attempted;
        const refreshedIds = new Set(result.refreshedExternalIds);
        const updates = result.products.flatMap((product) => {
          if (!refreshedIds.has(product.externalId)) return [];
          const row = sourceByExternalId.get(product.externalId);
          if (!row) return [];
          const sourceIsExact = product.categories[0]?.toLocaleLowerCase("lt") === "vyrams" && product.categories.length >= 2;
          const fallbackRoot = inferFallbackCategories(product.name, product.productTypes)[0];
          const categoryPath = normalizeCategoryPath(product.categories, sourceIsExact ? undefined : fallbackRoot);
          return [{
            id: row.id,
            colorOriginal: product.colorOriginal,
            colorFamily: product.colorFamily,
            colorShade: product.colorShade,
            categories: categoryPath.slice(1),
            categoryPath,
            categoriesExact: sourceIsExact,
            sizes: product.sizes,
            otherSizes: product.otherSizes,
            materials: product.materials,
            patterns: product.patterns,
            features: product.features,
            styles: product.styles,
            productTypes: product.productTypes
          }];
        });
        const { data, error } = await db.rpc("record_product_metadata_batch", { p_products: updates });
        if (error) throw error;
        refreshed += Number(data ?? updates.length);
        log(`Patikrinta ${attempted}/${products.length}, išsaugota ${refreshed}; paskutinis 25 produktų checkpoint įrašytas.`);
      }
    }
  } catch (error) {
    if (!(error instanceof AboutYouRateLimitError)) throw error;
    log(`ABOUT YOU pasiektas užklausų limitas. Išsaugoti checkpoint'ai lieka DB; kitas valandinis paleidimas tęs nuo likusių produktų.`);
  } finally {
    await context.close();
  }
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
      .eq("active", true).or("metadata_updated_at.is.null,category_path_updated_at.is.null").order("source_id").order("id").range(from, to);
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
    colorShade: row.color_shade, categories: [], categoryPath: [], sizes: row.sizes ?? [], otherSizes: row.other_sizes ?? [],
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
