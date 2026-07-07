import { chromium } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { enrichMissingProductMetadata } from "@catalog/aboutyou-provider";
import { normalizeCategoryPath, type Product } from "@catalog/shared";
import { inferFallbackCategories } from "./category-classifier";
import { cleanupOldDiagnostics, diagnosticRow, uploadDiagnosticHtml } from "./metadata-diagnostics";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  METADATA_SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(50_000).default(500),
  METADATA_SYNC_CONCURRENCY: z.coerce.number().int().min(1).max(12).default(3),
  METADATA_SYNC_DELAY_MS: z.coerce.number().int().min(250).max(60_000).default(750),
  METADATA_DEBUG_HTML_LIMIT: z.coerce.number().int().min(0).max(100).default(20),
  METADATA_DEBUG_RETENTION_DAYS: z.coerce.number().int().min(1).max(90).default(14),
  SYNC_HEADLESS: z.string().default("true").transform((value) => value !== "false")
});

const env = EnvSchema.parse(process.env);
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const startedAt = Date.now();
try {
  const deleted = await cleanupOldDiagnostics(db, env.METADATA_DEBUG_RETENTION_DAYS);
  if (deleted) log(`Pašalinta ${deleted} senų metaduomenų diagnostikos įrašų ir jų HTML failai.`);
} catch (error) {
  log(`Nepavyko išvalyti senos diagnostikos: ${errorMessage(error)}.`);
}
log(`Metaduomenų sync pradėtas (maxProducts=${env.METADATA_SYNC_MAX_PRODUCTS}).`);
const products = await loadActiveProducts();
log(`Atrinkta ${products.length} aktyvių produktų pagal seniausią detalės patikrinimą.`);

const browser = await chromium.launch({ headless: env.SYNC_HEADLESS });
let attempted = 0;
let refreshed = 0;
let debugHtmlSaved = 0;
try {
  const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  const page = await context.newPage();
  try {
    syncGroups: for (const sourceProducts of groupBySource(products).values()) {
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
        refreshed += result.refreshed;
        const productByExternalId = new Map(result.products.map((product) => [product.externalId, product]));
        const updates = result.attempts.flatMap((attempt) => {
          const row = sourceByExternalId.get(attempt.externalId);
          const product = productByExternalId.get(attempt.externalId);
          if (!row || !product) return [];
          const sourceIsExact = attempt.metadataFound && product.categories[0]?.toLocaleLowerCase("lt") === "vyrams" && product.categories.length >= 2;
          const fallbackRoot = attempt.metadataFound ? inferFallbackCategories(product.name, product.productTypes)[0] : undefined;
          const categoryPath = attempt.metadataFound
            ? normalizeCategoryPath(product.categories, sourceIsExact ? undefined : fallbackRoot)
            : [];
          return [{
            id: row.id,
            metadataFound: attempt.metadataFound,
            rawPayload: attempt.rawPayload,
            payloadHash: attempt.payloadHash,
            sourceEndpoint: attempt.sourceEndpoint,
            parserVersion: attempt.parserVersion,
            detailError: attempt.error,
            imageUrls: product.imageUrls,
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
        const { error } = await db.rpc("record_product_metadata_batch", { p_products: updates });
        if (error) throw error;
        const diagnostics = [];
        for (const attempt of result.attempts) {
          if (!attempt.error) continue;
          const row = sourceByExternalId.get(attempt.externalId);
          if (!row) continue;
          const checkedAt = new Date();
          let htmlStoragePath: string | null = null;
          if (attempt.error === "product_detail_payload_missing" && attempt.responseHtml && debugHtmlSaved < env.METADATA_DEBUG_HTML_LIMIT) {
            try {
              htmlStoragePath = await uploadDiagnosticHtml(db, row.id, attempt.responseHtml, checkedAt);
              debugHtmlSaved += 1;
            } catch (uploadError) {
              log(`Nepavyko išsaugoti ${row.external_id} diagnostikos HTML: ${errorMessage(uploadError)}.`);
            }
          }
          diagnostics.push(diagnosticRow(row.id, attempt, htmlStoragePath, checkedAt));
        }
        if (diagnostics.length) {
          const { error: diagnosticsError } = await db.from("product_sync_diagnostics").insert(diagnostics);
          if (diagnosticsError) log(`Nepavyko įrašyti ${diagnostics.length} diagnostikos eilučių: ${diagnosticsError.message}.`);
        }
        if (result.rateLimited) {
          log("ABOUT YOU pasiektas užklausų limitas. Užbaigti rezultatai išsaugoti; kitas paleidimas tęs nuo seniausiai tikrintų produktų.");
          break syncGroups;
        }
        log(`Patikrinta ${attempted}/${products.length}, išsaugota ${refreshed}; paskutinis 25 produktų checkpoint įrašytas.`);
      }
    }
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
      .select("id,source_id,external_id,name,brand,product_url,image_urls,color_original,color_family,color_shade,sizes,other_sizes,materials,patterns,features,styles,product_types,detail_checked_at")
      .eq("active", true)
      .order("detail_checked_at", { ascending: true, nullsFirst: true })
      .order("source_id").order("id").range(from, to);
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

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
function formatDuration(milliseconds: number): string {
  const seconds = Math.max(0, Math.round(milliseconds / 1_000));
  return seconds < 60 ? `${seconds} s` : `${Math.floor(seconds / 60)} min ${seconds % 60} s`;
}
