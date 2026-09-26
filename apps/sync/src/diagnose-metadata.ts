// Public source only: deliberately no dotenv or database client.
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { chromium } from "playwright";
import { fetchProductDetail, type ProductDetailNetworkEvent } from "@catalog/aboutyou-provider";
import { isAllowedAboutYouUrl } from "@catalog/shared";
import { classifyMetadataExtraction } from "./metadata-policy";

const urls = process.argv.slice(2);
if (!urls.length || urls.length > 10 || urls.some((url) => !isAllowedAboutYouUrl(url) || !new URL(url).pathname.startsWith("/p/"))) {
  throw new Error("Provide 1–10 public ABOUT YOU LT product URLs.");
}
const browser = await chromium.launch();
const results: Record<string, unknown>[] = [];
const directory = resolve("test-results/metadata-diagnostics");
await mkdir(resolve(directory, "traces"), { recursive: true });
try {
  const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  for (const [index, url] of urls.entries()) {
    const events: ProductDetailNetworkEvent[] = [];
    const tracePath = resolve(directory, "traces", `${String(index + 1).padStart(2, "0")}.zip`);
    const screenshotPath = resolve(directory, `timeout-${String(index + 1).padStart(2, "0")}.png`);
    let screenshot: string | null = null;
    await context.tracing.start({ screenshots: true, snapshots: true, sources: false });
    try {
      const result = await fetchProductDetail(context, url, 25_000, {
        onNetworkEvent: (event) => events.push(event),
        onFailure: async (page, error) => {
          if (!(error instanceof Error) || error.message !== "product_detail_request_timeout") return;
          try {
            await page.screenshot({ path: screenshotPath, fullPage: true, timeout: 5_000 });
            screenshot = `timeout-${String(index + 1).padStart(2, "0")}.png`;
          } catch (screenshotError) {
            events.push({ at: new Date().toISOString(), event: "page_error", error: `screenshot_failed:${String(screenshotError).slice(0, 300)}` });
          }
        }
      });
      const expectedId = new URL(url).pathname.match(/-(\d+)\/?$/)?.[1] ?? "";
      const failure = classifyMetadataExtraction(result.extraction, expectedId);
      const ok = result.status === 200 && !failure && new URL(result.finalUrl).pathname.startsWith("/p/");
      const summary = {
        url, status: result.status, finalUrl: result.finalUrl, mode: result.mode, ok,
        sourceProductId: result.extraction.sourceProductId, failure,
        images: result.extraction.metadata.imageUrls.length,
        sizes: result.extraction.metadata.sizeOptions.length,
        sections: result.extraction.metadata.sections.map(({ key, status }) => ({ key, status })),
        diagnostics: { trace: `traces/${String(index + 1).padStart(2, "0")}.zip`, screenshot, events }
      };
      results.push(summary);
      console.log(JSON.stringify(summary));
      if (!ok) process.exitCode = 1;
      if (result.status === 403 || result.status === 429) break;
    } catch (error) {
      results.push({
        url, ok: false, error: String(error),
        diagnostics: { trace: `traces/${String(index + 1).padStart(2, "0")}.zip`, screenshot, events }
      });
      console.error(String(error));
      process.exitCode = 1;
    } finally {
      await context.tracing.stop({ path: tracePath });
    }
  }
} finally {
  await browser.close();
  await writeFile(resolve(directory, "summary.json"), JSON.stringify(results, null, 2));
}
