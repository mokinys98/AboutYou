// Intentionally no dotenv, Supabase client, or application API access.
import { mkdir, appendFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { chromium } from "playwright";
import { collectAboutYouTarget } from "@catalog/aboutyou-provider";
import { isAllowedAboutYouUrl } from "@catalog/shared";
import { z } from "zod";

const args = z.tuple([z.string().url(), z.coerce.number().int().min(1).max(50_000), z.coerce.number().int().min(10_000).max(900_000)])
  .parse([process.argv[2], process.argv[3] ?? 100, process.argv[4] ?? 120_000]);
if (!isAllowedAboutYouUrl(args[0])) throw new Error("Leidžiami tik ABOUT YOU LT URL.");
const directory = resolve(fileURLToPath(new URL("../../../test-results/catalog-diagnostics/", import.meta.url)), new Date().toISOString().replace(/[:.]/g, "-"));
await mkdir(directory, { recursive: true });
let writes = Promise.resolve();
function log(event: Record<string, unknown>) {
  const line = JSON.stringify({ at: new Date().toISOString(), ...event }) + "\n";
  process.stdout.write(line);
  writes = writes.then(() => appendFile(resolve(directory, "events.jsonl"), line));
}
const started = Date.now();
const assetDelayMs = z.coerce.number().int().min(0).max(10_000).parse(process.argv[5] ?? 0);
const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  const page = await context.newPage();
  if (assetDelayMs) {
    // Reproduce slow CI hydration without contacting any application/database API.
    await page.route(/\/assets\/service\.grpc-[^/]+\.js/, async (route) => {
      await new Promise((resolve) => setTimeout(resolve, assetDelayMs));
      await route.continue();
    });
    log({ event: "diagnostic_asset_delay", delayMs: assetDelayMs });
  }
  page.on("response", (response) => {
    if (response.status() < 400) return;
    const url = new URL(response.url());
    log({ event: "http_error", status: response.status(), url: `${url.origin}${url.pathname}` });
  });
  page.on("console", (message) => {
    if (message.text().startsWith("[aboutyou-collector-event]")) log({ event: "collector_console", message: message.text().slice(0, 2000) });
  });
  const result = await collectAboutYouTarget(page, args[0], {
    maxProducts: args[1], timeoutMs: args[2],
    onDiagnostic: log, onProgress: (progress) => log({ event: "progress", ...progress })
  });
  const summary = { ...result, products: result.products.length, durationMs: Date.now() - started, requestedLimit: args[1] };
  // Capture schema/key shapes only; never persist session, basket or cookie values.
  const stateShapes = await page.evaluate(`(() => {
    const shape = (value, depth = 0) => {
      if (depth > 7) return "...";
      if (Array.isArray(value)) return { length: value.length, example: value.length ? shape(value[0], depth + 1) : null };
      if (value && typeof value === "object") return Object.fromEntries(Object.entries(value)
        .filter(([key]) => !/token|cookie|session|authorization/i.test(key))
        .map(([key, child]) => [key, shape(child, depth + 1)]));
      return typeof value;
    };
    return Array.from(document.querySelectorAll('script[data-tadarida-initial-state="true"]')).flatMap((script) => {
      try {
        return JSON.parse(script.textContent || "[]").map(([key, payload]) => ({
          key: String(key).split("?")[0].slice(0, 400), shape: shape(payload)
        }));
      } catch { return []; }
    });
  })()`);
  await writeFile(resolve(directory, "state-shapes.json"), JSON.stringify(stateShapes, null, 2));
  await writeFile(resolve(directory, "summary.json"), JSON.stringify(summary, null, 2));
  await writeFile(resolve(directory, "products.json"), JSON.stringify(result.products, null, 2));
  log({ event: "diagnosis_completed", ...summary, directory });
  if (!result.complete || result.rateLimited) process.exitCode = 1;
} catch (error) {
  log({ event: "diagnosis_failed", error: error instanceof Error ? error.message : String(error), durationMs: Date.now() - started, directory });
  process.exitCode = 1;
} finally {
  await browser.close();
  await writes;
}
