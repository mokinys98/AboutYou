import { chromium } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { AboutYouRateLimitError, collectAboutYouTarget, enrichMissingProductMetadata } from "@catalog/aboutyou-provider";
import { expandClothingCategoryPath, normalizeColor, normalizeColorShade, type Product } from "@catalog/shared";
import { inferFallbackCategories } from "./category-classifier";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(10_000).default(10_000),
  SYNC_COLOR_ENRICHMENT_LIMIT: z.coerce.number().int().min(0).max(10_000).default(100),
  SYNC_COLOR_ENRICHMENT_CONCURRENCY: z.coerce.number().int().min(1).max(12).default(1),
  SYNC_COLOR_ENRICHMENT_DELAY_MS: z.coerce.number().int().min(250).max(60_000).default(750),
  SYNC_HEADLESS: z.string().default("true").transform((value) => value !== "false")
});

const env = EnvSchema.parse(process.env);
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const startedAt = Date.now();
log(`Sinchronizavimas pradėtas (headless=${env.SYNC_HEADLESS}, maxProducts=${env.SYNC_MAX_PRODUCTS}).`);

const { data: targets, error: targetsError } = await withHeartbeat("Gaunamas sinchronizavimo grupių sąrašas", () => db.from("sync_targets")
  .select("id,source_id,kind,label,url,priority,requested_at,last_success_at")
  .eq("enabled", true)
  .order("requested_at", { ascending: false, nullsFirst: false })
  .order("priority", { ascending: true }));
if (targetsError) throw targetsError;
log(`Rasta aktyvių grupių: ${targets?.length ?? 0}.`);

const browser = await withHeartbeat("Paleidžiama Chromium naršyklė", () => chromium.launch({ headless: env.SYNC_HEADLESS }));
let failed = false;
try {
  for (const [index, target] of (targets ?? []).entries()) {
    const targetStartedAt = Date.now();
    log(`[${index + 1}/${targets?.length ?? 0}] Pradedama grupė „${target.label}“ (${target.url}).`);
    const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
    const page = await context.newPage();
    const { data: run, error: runError } = await db.from("sync_runs")
      .insert({ target_id: target.id, status: "running" }).select("id").single();
    if (runError || !run) throw runError ?? new Error("Nepavyko sukurti sync_run");
    await db.from("sync_targets").update({ last_started_at: new Date().toISOString() }).eq("id", target.id);

    let pages = 0;
    let productCount = 0;
    try {
      const result = await withHeartbeat(`„${target.label}“: renkami produktai`, () => retry(
        () => collectAboutYouTarget(page, target.url, {
          maxProducts: env.SYNC_MAX_PRODUCTS,
          onProgress: ({ products, expectedTotal, pages, mode }) => log(
            `„${target.label}“: surinkta ${products}${expectedTotal ? `/${Math.min(expectedTotal, env.SYNC_MAX_PRODUCTS)}` : ""} produktų (${pages} srauto psl., ${mode}).`
          )
        }),
        2,
        (attempt, error) => log(`„${target.label}“: ${attempt} bandymas nepavyko (${safeError(error)}), bus kartojama.`)
      ));
      pages = result.pages;
      if (result.products.length === 0) {
        throw new Error("Rinkimas negrąžino nė vieno produkto; tuščias rezultatas negali būti pažymėtas sėkmingu.");
      }
      if (!result.complete) {
        throw new Error(`Rinkimas nutrūko nepasiekęs tikslo: ${result.products.length}/${Math.min(result.expectedTotal ?? env.SYNC_MAX_PRODUCTS, env.SYNC_MAX_PRODUCTS)} produktų.`);
      }
      const productsWithKnownColors = await restoreKnownColors(target.source_id, result.products);
      const metadataResult = await enrichMissingProductMetadata(page, productsWithKnownColors, {
        limit: env.SYNC_COLOR_ENRICHMENT_LIMIT,
        concurrency: env.SYNC_COLOR_ENRICHMENT_CONCURRENCY,
        delayMs: env.SYNC_COLOR_ENRICHMENT_DELAY_MS,
        onProgress: ({ processed, total, foundColors, foundCategories }) => log(
          `„${target.label}“: metaduomenys ${processed}/${total}, spalvos ${foundColors}, kategorijų keliai ${foundCategories}.`
        )
      });
      if (metadataResult.attempted) {
        log(`„${target.label}“: metaduomenų praturtinimas baigtas, spalvos ${metadataResult.foundColors}, kategorijų keliai ${metadataResult.foundCategories}/${metadataResult.attempted}.`);
      }
      const products = metadataResult.products.map((product) => {
        const sourceCategories = product.categories;
        const targetCategories = target.kind === "category" ? [target.label] : [];
        const exactCategories = expandClothingCategoryPath([...sourceCategories, ...targetCategories]);
        const fallbackCategories = expandClothingCategoryPath([
          ...targetCategories,
          ...inferFallbackCategories(product.name, product.productTypes)
        ]);
        return {
          ...product,
          // A category target is itself an authoritative membership. Keep it even
          // when ABOUT YOU only exposes a more specific breadcrumb leaf.
          categories: exactCategories.length ? exactCategories : fallbackCategories,
          categoriesExact: sourceCategories.length > 0 && exactCategories.length > 0
        };
      });
      log(`„${target.label}“: surinkta ${products.length} produktų iš ${pages} psl.; pradedamas saugojimas.`);
      for (const batch of chunks(products, 200)) {
        const { data: saved, error } = await db.rpc("record_catalog_batch", {
          p_source_id: target.source_id,
          p_target_id: target.id,
          p_run_id: run.id,
          p_products: batch
        });
        if (error) throw error;
        productCount += Number(saved ?? batch.length);
        log(`„${target.label}“: išsaugota ${productCount}/${products.length} produktų.`);
      }
      const { error: finishError } = await db.rpc("finish_sync_run", {
        p_run_id: run.id, p_status: "success", p_pages_count: pages,
        p_products_count: productCount, p_error: null
      });
      if (finishError) throw finishError;
      log(`„${target.label}“ baigta sėkmingai: ${productCount} produktų, ${pages} psl., ${formatDuration(Date.now() - targetStartedAt)}.`);
    } catch (error) {
      failed = true;
      const message = safeError(error);
      await db.rpc("finish_sync_run", {
        p_run_id: run.id, p_status: productCount ? "partial" : "failed", p_pages_count: pages,
        p_products_count: productCount, p_error: message
      });
      console.error(JSON.stringify({ target: target.label, status: "failed", error: message }));
    } finally {
      await context.close();
    }
  }
  await withHeartbeat("Valoma sena kainų istorija", () => db.rpc("cleanup_price_history"));
} finally {
  await browser.close();
}

log(`Sinchronizavimas baigtas ${failed ? "su klaidomis" : "sėkmingai"} per ${formatDuration(Date.now() - startedAt)}.`);
if (failed) process.exitCode = 1;

async function retry<T>(operation: () => Promise<T>, attempts: number, onRetry?: (attempt: number, error: unknown) => void): Promise<T> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try { return await operation(); }
    catch (error) {
      lastError = error;
      if (error instanceof AboutYouRateLimitError) break;
      if (attempt < attempts) {
        onRetry?.(attempt, error);
        await new Promise((resolve) => setTimeout(resolve, 1_000 * 2 ** (attempt - 1)));
      }
    }
  }
  throw lastError;
}

async function withHeartbeat<T>(label: string, operation: () => PromiseLike<T>): Promise<T> {
  const operationStartedAt = Date.now();
  log(`${label}...`);
  const heartbeat = setInterval(() => {
    log(`${label} – vis dar vykdoma (${formatDuration(Date.now() - operationStartedAt)}).`);
  }, 15_000);
  heartbeat.unref();
  try {
    return await operation();
  } finally {
    clearInterval(heartbeat);
  }
}

function log(message: string): void {
  console.log(`[sync ${new Date().toISOString()}] ${message}`);
}

function formatDuration(milliseconds: number): string {
  const seconds = Math.max(0, Math.round(milliseconds / 1_000));
  if (seconds < 60) return `${seconds} s`;
  return `${Math.floor(seconds / 60)} min ${seconds % 60} s`;
}

function chunks<T>(items: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let index = 0; index < items.length; index += size) result.push(items.slice(index, index + size));
  return result;
}

async function restoreKnownColors(sourceId: string, products: Product[]): Promise<Product[]> {
  const known = new Map<string, string>();
  for (const batch of chunks(products.map((product) => product.externalId), 200)) {
    const { data, error } = await db.from("products").select("external_id,color_original")
      .eq("source_id", sourceId).in("external_id", batch).not("color_original", "is", null);
    if (error) throw error;
    for (const row of data ?? []) {
      if (row.color_original) known.set(row.external_id, row.color_original);
    }
  }
  return products.map((product) => {
    const colorOriginal = product.colorOriginal ?? known.get(product.externalId);
    return colorOriginal ? {
      ...product,
      colorOriginal,
      colorFamily: normalizeColor(colorOriginal),
      colorShade: normalizeColorShade(colorOriginal)
    } : product;
  });
}

function safeError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.replace(/(?:bearer|authorization|cookie|token)[^,}\n]*/gi, "[redacted]").slice(0, 2_000);
}
