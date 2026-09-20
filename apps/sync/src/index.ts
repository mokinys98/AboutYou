import { chromium, type BrowserContext } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { AboutYouRateLimitError, collectAboutYouTarget } from "@catalog/aboutyou-provider";
import { normalizeCategoryPath } from "@catalog/shared";
import { inferFallbackCategoryPath, resolveFallbackCategory } from "./category-classifier";
import { saveCatalogBatchResilient, type CatalogBatchFailureEvent, type CatalogBatchRejected } from "./catalog-batches";
import { formatSyncError } from "./sync-errors";
import { selectSyncTargets } from "./target-selection";
import { catalogCollectionIssue } from "./catalog-policy";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(50_000).default(10_000),
  SYNC_TARGET_LABEL: z.string().default(""),
  SYNC_COLLECTION_TIMEOUT_MS: z.coerce.number().int().min(10_000).max(900_000).default(480_000),
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
const selectedTargets = selectSyncTargets(targets ?? [], env.SYNC_TARGET_LABEL);
if (env.SYNC_TARGET_LABEL && selectedTargets.length === 0) throw new Error(`Nerastas aktyvus sync target: ${env.SYNC_TARGET_LABEL}`);
log(`Rasta aktyvių grupių: ${selectedTargets.length}.`);

const browser = await withHeartbeat("Paleidžiama Chromium naršyklė", () => chromium.launch({ headless: env.SYNC_HEADLESS }));
let failed = false;
try {
  for (const [index, target] of selectedTargets.entries()) {
    const targetStartedAt = Date.now();
    log(`[${index + 1}/${selectedTargets.length}] Pradedama grupė „${target.label}“ (${target.url}).`);
    const collectionSession: { context: BrowserContext | null } = { context: null };
    const { data: run, error: runError } = await db.from("sync_runs")
      .insert({ target_id: target.id, status: "running" }).select("id").single();
    if (runError || !run) throw runError ?? new Error("Nepavyko sukurti sync_run");
    await db.from("sync_targets").update({ last_started_at: new Date().toISOString() }).eq("id", target.id);

    let pages = 0;
    let productCount = 0;
    let rejectedProducts: CatalogBatchRejected[] = [];
    try {
      const result = await withHeartbeat(`„${target.label}“: renkami produktai`, () => retry(
        async (attempt) => {
          const attemptStartedAt = Date.now();
          logEvent("catalog_collection_attempt_started", { target: target.label, attempt });
          const previousContext = collectionSession.context;
          collectionSession.context = null;
          await closeBrowserContext(previousContext, { target: target.label, attempt, phase: "before_attempt" });
          collectionSession.context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
          const page = await collectionSession.context.newPage();
          attachPageDiagnostics(page, target.label, attempt);
          logEvent("catalog_browser_page_ready", { target: target.label, attempt });
          const collection = await collectAboutYouTarget(page, target.url, {
            maxProducts: env.SYNC_MAX_PRODUCTS,
            timeoutMs: env.SYNC_COLLECTION_TIMEOUT_MS,
            directStream: attempt === 1,
            onProgress: ({ products, expectedTotal, pages, mode }) => log(
              `„${target.label}“: surinkta ${products}${expectedTotal ? `/${Math.min(expectedTotal, env.SYNC_MAX_PRODUCTS)}` : ""} produktų (${pages} srauto psl., ${mode}).`
            ),
            onDiagnostic: ({ event, at, ...details }) => logEvent("aboutyou_collection_diagnostic", {
              target: target.label,
              attempt,
              collection_event: event,
              collection_event_at: at,
              ...details
            })
          });
          logEvent("catalog_collection_attempt_completed", {
            target: target.label,
            attempt,
            duration_ms: Date.now() - attemptStartedAt,
            products: collection.products.length,
            pages: collection.pages,
            mode: collection.mode,
            complete: collection.complete
          });
          return collection;
        },
        2,
        (attempt, error) => log(`„${target.label}“: ${attempt} bandymas nepavyko (${safeError(error)}), bus kartojama.`)
      ));
      pages = result.pages;
      if (result.products.length === 0) {
        throw new Error("Rinkimas negrąžino nė vieno produkto; tuščias rezultatas negali būti pažymėtas sėkmingu.");
      }
      const collectionIssue = catalogCollectionIssue(result, env.SYNC_MAX_PRODUCTS);
      logEvent("catalog_collection_summary", {
        run_id: run.id, target: target.label, collected: result.products.length,
        expected_total: result.expectedTotal, mode: result.mode,
        duration_ms: Date.now() - targetStartedAt, issue: collectionIssue
      });
      const products = result.products.map((product) => {
        const sourceCategories = product.categories;
        const sourceIsExact = sourceCategories[0]?.toLocaleLowerCase("lt") === "vyrams" && sourceCategories.length >= 2;
        const fallbackRoot = resolveFallbackCategory(
          product.name,
          product.productTypes,
          target.kind === "category" ? target.label : undefined
        );
        const inferredPath = inferFallbackCategoryPath(product.name, product.productTypes);
        const categoryPath = sourceIsExact
          ? normalizeCategoryPath(sourceCategories)
          : inferredPath.length
            ? inferredPath
          : fallbackRoot
            ? normalizeCategoryPath(sourceCategories, fallbackRoot)
            : [];
        return {
          ...product,
          // A category target is itself an authoritative membership. Keep it even
          // when ABOUT YOU only exposes a more specific breadcrumb leaf.
          categories: categoryPath.slice(1),
          categoryPath,
          categoriesExact: sourceIsExact
        };
      });
      log(`„${target.label}“: surinkta ${products.length} produktų iš ${pages} psl.; pradedamas saugojimas.`);
      for (const [batchIndex, batch] of chunks(products, 200).entries()) {
        const result = await saveCatalogBatchResilient({
          items: batch,
          save: async (items) => {
            const { data: saved, error } = await db.rpc("record_catalog_batch", {
              p_source_id: target.source_id,
              p_target_id: target.id,
              p_run_id: run.id,
              p_products: items
            });
            if (error) throw error;
            return Number(saved ?? items.length);
          },
          onFailure: (event: CatalogBatchFailureEvent) => {
            console.error(JSON.stringify({
              event: "catalog_batch_failed",
              target: target.label,
              run_id: run.id,
              batch_index: batchIndex,
              ...event
            }));
          }
        });
        productCount += result.saved;
        rejectedProducts = [...rejectedProducts, ...result.rejected];
        log(`„${target.label}“: išsaugota ${productCount}/${products.length} produktų.`);
      }
      const finalStatus = rejectedProducts.length || collectionIssue ? "partial" : "success";
      const finalError = finalStatus === "partial"
        ? JSON.stringify({ collection_issue: collectionIssue, rejected_products: rejectedProducts.slice(0, 50) }).slice(0, 2_000)
        : null;
      const { error: finishError } = await db.rpc("finish_sync_run", {
        p_run_id: run.id, p_status: finalStatus, p_pages_count: pages,
        p_products_count: productCount, p_error: finalError
      });
      if (finishError) throw finishError;
      if (finalStatus === "partial") {
        failed = true;
        console.error(JSON.stringify({ event: "catalog_target_partial", target: target.label, collection_issue: collectionIssue, rejected_products: rejectedProducts }));
        log(`„${target.label}“ baigta dalinai: ${productCount}/${products.length} produktų, ${rejectedProducts.length} atmesta.`);
      } else {
        log(`„${target.label}“ baigta sėkmingai: ${productCount} produktų, ${pages} psl., ${formatDuration(Date.now() - targetStartedAt)}.`);
      }
      if (result.rateLimited) {
        logEvent("catalog_rate_limit_stop", { target: target.label });
        break;
      }
    } catch (error) {
      failed = true;
      const message = safeError(error);
      const { error: failureRecordError } = await db.rpc("finish_sync_run", {
        p_run_id: run.id, p_status: productCount ? "partial" : "failed", p_pages_count: pages,
        p_products_count: productCount, p_error: message
      });
      if (failureRecordError) logEvent("catalog_failure_record_failed", { run_id: run.id, error: safeError(failureRecordError) });
      console.error(JSON.stringify({ target: target.label, status: "failed", error: message }));
      if (error instanceof AboutYouRateLimitError) break;
    } finally {
      const finalContext = collectionSession.context;
      collectionSession.context = null;
      await closeBrowserContext(finalContext, { target: target.label, phase: "target_finally" });
    }
  }
  await withHeartbeat("Valoma sena kainų istorija", () => db.rpc("cleanup_price_history"));
  const { data: refreshVersion, error: refreshRequestError } = await db.rpc("request_catalog_items_read_refresh");
  if (refreshRequestError) {
    console.error(JSON.stringify({
      event: "catalog_read_model_refresh_request_failed",
      error: formatSyncError(refreshRequestError)
    }));
  } else {
    console.log(JSON.stringify({
      event: "catalog_read_model_refresh_requested",
      requested_version: refreshVersion
    }));
  }
} finally {
  await browser.close();
}

log(`Sinchronizavimas baigtas ${failed ? "su klaidomis" : "sėkmingai"} per ${formatDuration(Date.now() - startedAt)}.`);
if (failed) process.exitCode = 1;

async function retry<T>(operation: (attempt: number) => Promise<T>, attempts: number, onRetry?: (attempt: number, error: unknown) => void): Promise<T> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try { return await operation(attempt); }
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

function safeError(error: unknown): string {
  return formatSyncError(error);
}

function logEvent(event: string, details: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ event, at: new Date().toISOString(), ...details }));
}

function attachPageDiagnostics(page: import("playwright").Page, target: string, attempt: number): void {
  page.on("response", (response) => {
    const url = response.url();
    const isStream = url.includes("tadarida-web.aboutyou.com");
    if (!isStream && response.status() < 400) return;
    logEvent("catalog_browser_response", {
      target,
      attempt,
      status: response.status(),
      resource_type: response.request().resourceType(),
      url: safeNetworkUrl(url)
    });
  });
  page.on("requestfailed", (request) => {
    const url = request.url();
    if (!url.includes("aboutyou") && request.resourceType() !== "document") return;
    logEvent("catalog_browser_request_failed", {
      target,
      attempt,
      resource_type: request.resourceType(),
      error: request.failure()?.errorText ?? "unknown",
      url: safeNetworkUrl(url)
    });
  });
  page.on("pageerror", (error) => logEvent("catalog_browser_page_error", {
    target,
    attempt,
    error: error.message.slice(0, 500)
  }));
  page.on("console", (message) => {
    const text = message.text();
    const isCollectorEvent = text.startsWith("[aboutyou-collector-event]");
    if (!isCollectorEvent && message.type() !== "warning" && message.type() !== "error") return;
    logEvent("catalog_browser_console", {
      target,
      attempt,
      level: message.type(),
      message: text.slice(0, 1_000)
    });
  });
}

async function closeBrowserContext(
  context: BrowserContext | null,
  details: Record<string, unknown>,
  timeoutMs = 10_000
): Promise<void> {
  if (!context) return;
  const startedAt = Date.now();
  logEvent("catalog_browser_context_close_started", details);
  let timeout: ReturnType<typeof setTimeout> | undefined;
  const outcome = await Promise.race([
    context.close().then(() => "closed" as const).catch((error) => {
      logEvent("catalog_browser_context_close_failed", { ...details, error: safeError(error) });
      return "failed" as const;
    }),
    new Promise<"timeout">((resolve) => {
      timeout = setTimeout(() => resolve("timeout"), timeoutMs);
      timeout.unref();
    })
  ]);
  if (timeout) clearTimeout(timeout);
  logEvent(outcome === "timeout" ? "catalog_browser_context_close_timeout" : "catalog_browser_context_close_completed", {
    ...details,
    outcome,
    duration_ms: Date.now() - startedAt
  });
}

function safeNetworkUrl(value: string): string {
  try {
    const url = new URL(value);
    return `${url.origin}${url.pathname}`;
  } catch {
    return value.slice(0, 300);
  }
}
