import { chromium } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { collectAboutYouTarget } from "@catalog/aboutyou-provider";
import type { Product } from "@catalog/shared";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(10_000).default(10_000),
  SYNC_HEADLESS: z.string().default("true").transform((value) => value !== "false")
});

const env = EnvSchema.parse(process.env);
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const { data: targets, error: targetsError } = await db.from("sync_targets")
  .select("id,source_id,kind,label,url,priority,requested_at,last_success_at")
  .eq("enabled", true)
  .order("requested_at", { ascending: false, nullsFirst: false })
  .order("priority", { ascending: true });
if (targetsError) throw targetsError;

const browser = await chromium.launch({ headless: env.SYNC_HEADLESS });
let failed = false;
try {
  for (const target of targets ?? []) {
    const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
    const page = await context.newPage();
    const { data: run, error: runError } = await db.from("sync_runs")
      .insert({ target_id: target.id, status: "running" }).select("id").single();
    if (runError || !run) throw runError ?? new Error("Nepavyko sukurti sync_run");
    await db.from("sync_targets").update({ last_started_at: new Date().toISOString() }).eq("id", target.id);

    let pages = 0;
    let productCount = 0;
    try {
      const result = await retry(() => collectAboutYouTarget(page, target.url, { maxProducts: env.SYNC_MAX_PRODUCTS }), 3);
      pages = result.pages;
      for (const batch of chunks(result.products, 200)) {
        const { data: saved, error } = await db.rpc("record_catalog_batch", {
          p_source_id: target.source_id,
          p_target_id: target.id,
          p_run_id: run.id,
          p_products: batch
        });
        if (error) throw error;
        productCount += Number(saved ?? batch.length);
      }
      const { error: finishError } = await db.rpc("finish_sync_run", {
        p_run_id: run.id, p_status: "success", p_pages_count: pages,
        p_products_count: productCount, p_error: null
      });
      if (finishError) throw finishError;
      console.log(JSON.stringify({ target: target.label, status: "success", products: productCount, pages, mode: result.mode }));
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
  await db.rpc("cleanup_price_history");
} finally {
  await browser.close();
}

if (failed) process.exitCode = 1;

async function retry<T>(operation: () => Promise<T>, attempts: number): Promise<T> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try { return await operation(); }
    catch (error) {
      lastError = error;
      if (attempt < attempts) await new Promise((resolve) => setTimeout(resolve, 1_000 * 2 ** (attempt - 1)));
    }
  }
  throw lastError;
}

function chunks<T>(items: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let index = 0; index < items.length; index += size) result.push(items.slice(index, index + size));
  return result;
}

function safeError(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.replace(/(?:bearer|authorization|cookie|token)[^,}\n]*/gi, "[redacted]").slice(0, 2_000);
}

