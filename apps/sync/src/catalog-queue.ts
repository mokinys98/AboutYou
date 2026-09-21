import { chromium, type BrowserContext, type Page } from "playwright";
import { createHash } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { AboutYouRateLimitError, collectAboutYouTarget } from "@catalog/aboutyou-provider";
import { normalizeCategoryPath, type Product } from "@catalog/shared";
import { inferFallbackCategoryPath, resolveFallbackCategory } from "./category-classifier";
import { formatSyncError } from "./sync-errors";

type QueueDb = {
  rpc: (name: string, args?: Record<string, unknown>) => Promise<{ data: unknown; error: unknown | null }>;
};

export const CatalogQueueEnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(15_000).default(5_000),
  SYNC_TARGET_LABEL: z.string().default(""),
  SYNC_COLLECTION_TIMEOUT_MS: z.coerce.number().int().min(10_000).max(600_000).default(480_000),
  SYNC_WORK_BUDGET_MS: z.coerce.number().int().min(60_000).max(720_000).default(600_000),
  SYNC_HEADLESS: z.string().default("true").transform((value) => value !== "false")
});
export type CatalogQueueEnv = z.infer<typeof CatalogQueueEnvSchema>;

type ClaimedTask = {
  task_id: string; lease_token: string; cycle_id: string; sync_run_id: string;
  target_id: string; source_id: string; target_label: string; target_kind: "category" | "brand" | "search";
  part_key: string; part_url: string; attempt: number; lease_until: string;
};

export function retryDelayMinutes(attempt: number): 5 | 15 | 60 {
  return attempt <= 1 ? 5 : attempt === 2 ? 15 : 60;
}

export async function runCatalogQueue(env: CatalogQueueEnv): Promise<void> {
  const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } }) as unknown as QueueDb;
  const startedAt = Date.now();
  const deadline = startedAt + env.SYNC_WORK_BUDGET_MS;
  let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;
  let wroteProducts = false;
  let claimedCount = 0;
  logEvent("catalog_queue_worker_started", { work_budget_ms: env.SYNC_WORK_BUDGET_MS, product_limit: env.SYNC_MAX_PRODUCTS });
  try {
    browser = await chromium.launch({ headless: env.SYNC_HEADLESS });
    while (Date.now() < deadline) {
      const { data, error } = await db.rpc("claim_catalog_collection_task", { p_target_label: env.SYNC_TARGET_LABEL });
      if (error) throw error;
      const task = Array.isArray(data) ? data[0] as ClaimedTask | undefined : undefined;
      if (!task) {
        logEvent("catalog_queue_no_runnable_task", { target_label: env.SYNC_TARGET_LABEL || null });
        break;
      }
      claimedCount += 1;
      const remainingMs = deadline - Date.now();
      if (remainingMs < 60_000) {
        await finishTask(db, task, false, null, 0, 0, "Darbo biudžetas baigėsi prieš pradedant rinkimą.", false, null);
        break;
      }
      const outcome = await collectTask(db, browser, task, env, Math.min(env.SYNC_COLLECTION_TIMEOUT_MS, remainingMs - 30_000));
      wroteProducts ||= outcome.wroteProducts;
      if (outcome.rateLimited) break;
    }
    if (wroteProducts) {
      await db.rpc("cleanup_price_history");
      const { data: version, error } = await db.rpc("request_catalog_items_read_refresh");
      if (error) logEvent("catalog_read_model_refresh_request_failed", { error: safeError(error) });
      else logEvent("catalog_read_model_refresh_requested", { requested_version: version });
    }
  } finally {
    await browser?.close();
    logEvent("catalog_queue_worker_finished", { claimed_tasks: claimedCount, wrote_products: wroteProducts, duration_ms: Date.now() - startedAt });
  }
}

async function collectTask(
  db: QueueDb, browser: Awaited<ReturnType<typeof chromium.launch>>,
  task: ClaimedTask, env: CatalogQueueEnv, timeoutMs: number
): Promise<{ wroteProducts: boolean; rateLimited: boolean }> {
  let context: BrowserContext | null = null;
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  try {
    logEvent("catalog_queue_task_started", { task_id: task.task_id, cycle_id: task.cycle_id, target: task.target_label, part: task.part_key, attempt: task.attempt });
    context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
    const page = await context.newPage();
    attachPageDiagnostics(page, task);
    heartbeat = setInterval(() => {
      void db.rpc("renew_catalog_collection_lease", { p_task_id: task.task_id, p_lease_token: task.lease_token })
        .then(({ error }) => { if (error) logEvent("catalog_queue_lease_renew_failed", { task_id: task.task_id, error: safeError(error) }); });
    }, 30_000);
    heartbeat.unref();
    const result = await collectAboutYouTarget(page, task.part_url, {
      maxProducts: env.SYNC_MAX_PRODUCTS,
      timeoutMs,
      directStream: true,
      allowScrollFallback: false,
      onProgress: (progress) => logEvent("catalog_queue_progress", { task_id: task.task_id, ...progress }),
      onDiagnostic: ({ event, at, ...details }) => logEvent("aboutyou_collection_diagnostic", { task_id: task.task_id, cycle_id: task.cycle_id, collection_event: event, collection_event_at: at, ...details })
    });
    const products = mapProducts(result.products, task);
    let saved = 0;
    for (const [index, batch] of chunks(products, 200).entries()) {
      const { data, error } = await db.rpc("record_catalog_collection_page", {
        p_task_id: task.task_id, p_lease_token: task.lease_token, p_page_number: index + 1,
        p_page_key: pageKey(batch), p_products: batch
      });
      if (error) throw error;
      saved += Number(data ?? 0);
    }
    const complete = result.complete && result.expectedTotal !== null && products.length >= result.expectedTotal;
    const issue = complete ? null : result.error || (result.expectedTotal === null
      ? "Šaltinis negrąžino bendro prekių skaičiaus."
      : `Nepilnas rinkimas: ${products.length}/${result.expectedTotal}.`);
    const status = await finishTask(db, task, complete, result.expectedTotal, products.length, result.pages, issue, result.rateLimited ?? false, result.retryAfterSeconds ?? null);
    logEvent("catalog_queue_task_finished", { task_id: task.task_id, cycle_id: task.cycle_id, status, saved, collected: products.length, expected_total: result.expectedTotal, pages: result.pages, mode: result.mode, issue });
    return { wroteProducts: saved > 0, rateLimited: result.rateLimited ?? false };
  } catch (error) {
    const rateLimited = error instanceof AboutYouRateLimitError;
    const message = safeError(error);
    const status = await finishTask(db, task, false, null, 0, 0, message, rateLimited, null).catch((finishError) => {
      logEvent("catalog_queue_finish_failed", { task_id: task.task_id, error: safeError(finishError) });
      return "finish_failed";
    });
    logEvent("catalog_queue_task_failed", { task_id: task.task_id, cycle_id: task.cycle_id, status, rate_limited: rateLimited, error: message });
    return { wroteProducts: false, rateLimited };
  } finally {
    if (heartbeat) clearInterval(heartbeat);
    await context?.close().catch(() => undefined);
  }
}

async function finishTask(
  db: QueueDb, task: ClaimedTask, complete: boolean, expectedTotal: number | null,
  collectedCount: number, pagesCount: number, error: string | null, rateLimited: boolean, retryAfterSeconds: number | null
): Promise<string> {
  const { data, error: finishError } = await db.rpc("finish_catalog_collection_task", {
    p_task_id: task.task_id, p_lease_token: task.lease_token, p_complete: complete,
    p_expected_total: expectedTotal, p_collected_count: collectedCount, p_pages_count: pagesCount,
    p_error: error, p_rate_limited: rateLimited, p_retry_after_seconds: retryAfterSeconds
  });
  if (finishError) throw finishError;
  return String(data);
}

function mapProducts(products: Product[], task: ClaimedTask): Product[] {
  return products.map((product) => {
    const sourceCategories = product.categories;
    const sourceIsExact = sourceCategories[0]?.toLocaleLowerCase("lt") === "vyrams" && sourceCategories.length >= 2;
    const fallbackRoot = resolveFallbackCategory(product.name, product.productTypes, task.target_kind === "category" ? task.target_label : undefined);
    const inferredPath = inferFallbackCategoryPath(product.name, product.productTypes);
    const categoryPath = sourceIsExact ? normalizeCategoryPath(sourceCategories)
      : inferredPath.length ? inferredPath : fallbackRoot ? normalizeCategoryPath(sourceCategories, fallbackRoot) : [];
    return { ...product, categories: categoryPath.slice(1), categoryPath, categoriesExact: sourceIsExact };
  });
}

function chunks<T>(items: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let index = 0; index < items.length; index += size) result.push(items.slice(index, index + size));
  return result;
}
function pageKey(products: Product[]): string {
  return createHash("sha256").update(products.map((product) => product.externalId).sort().join(",")).digest("hex");
}
function safeError(error: unknown): string { return formatSyncError(error); }
function logEvent(event: string, details: Record<string, unknown> = {}): void { console.log(JSON.stringify({ event, at: new Date().toISOString(), ...details })); }
function attachPageDiagnostics(page: Page, task: ClaimedTask): void {
  page.on("response", (response) => {
    if (response.status() < 400) return;
    logEvent("catalog_browser_response", { task_id: task.task_id, status: response.status(), resource_type: response.request().resourceType(), url: safeNetworkUrl(response.url()) });
  });
  page.on("requestfailed", (request) => logEvent("catalog_browser_request_failed", { task_id: task.task_id, resource_type: request.resourceType(), error: request.failure()?.errorText ?? "unknown", url: safeNetworkUrl(request.url()) }));
}
function safeNetworkUrl(value: string): string { try { const url = new URL(value); return `${url.origin}${url.pathname}`; } catch { return value.slice(0, 300); } }
