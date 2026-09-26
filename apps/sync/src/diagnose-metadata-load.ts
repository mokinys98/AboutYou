// Public source only: deliberately no dotenv or database client.
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { chromium } from "playwright";
import { fetchProductDetail, type ProductDetailNetworkEvent } from "@catalog/aboutyou-provider";
import { isAllowedAboutYouUrl } from "@catalog/shared";
import { classifyMetadataExtraction } from "./metadata-policy";

const urls = (process.env.DIAGNOSE_METADATA_URLS ?? "").split(/\r?\n/).map((url) => url.trim()).filter(Boolean);
const repeatCount = parsePositiveInteger(process.env.DIAGNOSE_METADATA_REPEAT_COUNT, 35, 50, "DIAGNOSE_METADATA_REPEAT_COUNT");
const concurrency = parsePositiveInteger(process.env.DIAGNOSE_METADATA_CONCURRENCY, 3, 3, "DIAGNOSE_METADATA_CONCURRENCY");
if (!urls.length || urls.length > 20 || urls.some((url) => !isAllowedAboutYouUrl(url) || !new URL(url).pathname.startsWith("/p/"))) {
  throw new Error("Provide 1–20 public ABOUT YOU LT product URLs in DIAGNOSE_METADATA_URLS.");
}

const tasks = Array.from({ length: repeatCount }, () => urls).flat();
const directory = resolve("test-results/metadata-load-diagnostics");
await mkdir(directory, { recursive: true });

const browser = await chromium.launch();
const results: Record<string, unknown>[] = [];
let nextTask = 0;
let stoppedOnTimeout = false;
try {
  const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  await context.tracing.start({ screenshots: true, snapshots: false, sources: false });
  try {
    await Promise.all(Array.from({ length: concurrency }, () => worker(context)));
  } finally {
    await context.tracing.stop({ path: resolve(directory, "trace.zip") });
  }
} finally {
  await browser.close();
  await writeFile(resolve(directory, "summary.json"), JSON.stringify({
    urls, repeatCount, concurrency, requested: tasks.length, started: nextTask,
    stoppedOnTimeout, results
  }, null, 2));
}

function parsePositiveInteger(value: string | undefined, fallback: number, maximum: number, name: string): number {
  if (value === undefined || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > maximum) throw new Error(`${name} must be an integer from 1 to ${maximum}.`);
  return parsed;
}

async function worker(context: Awaited<ReturnType<typeof browser.newContext>>): Promise<void> {
  while (!stoppedOnTimeout) {
    const index = nextTask;
    const url = tasks[index];
    if (!url) return;
    nextTask += 1;
    const events: ProductDetailNetworkEvent[] = [];
    const screenshotName = `timeout-${String(index + 1).padStart(3, "0")}.png`;
    let screenshot: string | null = null;
    try {
      const result = await fetchProductDetail(context, url, 25_000, {
        onNetworkEvent: (event) => events.push(event),
        onFailure: async (page, error) => {
          if (!(error instanceof Error) || error.message !== "product_detail_request_timeout") return;
          try {
            await page.screenshot({ path: resolve(directory, screenshotName), fullPage: true, timeout: 5_000 });
            screenshot = screenshotName;
          } catch (screenshotError) {
            events.push({ at: new Date().toISOString(), event: "page_error", error: `screenshot_failed:${String(screenshotError).slice(0, 300)}` });
          }
        }
      });
      const expectedId = new URL(url).pathname.match(/-(\d+)\/?$/)?.[1] ?? "";
      const failure = classifyMetadataExtraction(result.extraction, expectedId);
      results[index] = {
        sequence: index + 1, url, ok: result.status === 200 && !failure,
        status: result.status, finalUrl: result.finalUrl, mode: result.mode,
        sourceProductId: result.extraction.sourceProductId, failure,
        events
      };
      console.log(JSON.stringify({ event: "metadata_load_result", sequence: index + 1, ok: result.status === 200 && !failure, status: result.status, mode: result.mode }));
    } catch (error) {
      const timeout = error instanceof Error && error.message === "product_detail_request_timeout";
      results[index] = { sequence: index + 1, url, ok: false, error: String(error), screenshot, events };
      console.error(JSON.stringify({ event: "metadata_load_failed", sequence: index + 1, timeout, error: String(error) }));
      if (timeout) stoppedOnTimeout = true;
    }
  }
}
