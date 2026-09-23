// Public source only: deliberately no dotenv or database client.
import { mkdir, writeFile } from "node:fs/promises";
import { chromium } from "playwright";
import { fetchProductDetail } from "@catalog/aboutyou-provider";
import { isAllowedAboutYouUrl } from "@catalog/shared";
import { classifyMetadataExtraction } from "./metadata-policy";

const urls = process.argv.slice(2);
if (!urls.length || urls.length > 10 || urls.some((url) => !isAllowedAboutYouUrl(url) || !new URL(url).pathname.startsWith("/p/"))) {
  throw new Error("Provide 1–10 public ABOUT YOU LT product URLs.");
}
const browser = await chromium.launch();
const results: Record<string, unknown>[] = [];
try {
  const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  for (const url of urls) {
    try {
      const result = await fetchProductDetail(context, url);
      const expectedId = new URL(url).pathname.match(/-(\d+)\/?$/)?.[1] ?? "";
      const failure = classifyMetadataExtraction(result.extraction, expectedId);
      const ok = result.status === 200 && !failure && new URL(result.finalUrl).pathname.startsWith("/p/");
      const summary = {
        url, status: result.status, finalUrl: result.finalUrl, mode: result.mode, ok,
        sourceProductId: result.extraction.sourceProductId, failure,
        images: result.extraction.metadata.imageUrls.length,
        sizes: result.extraction.metadata.sizeOptions.length,
        sections: result.extraction.metadata.sections.map(({ key, status }) => ({ key, status }))
      };
      results.push(summary);
      console.log(JSON.stringify(summary));
      if (!ok) process.exitCode = 1;
      if (result.status === 403 || result.status === 429) break;
    } catch (error) {
      results.push({ url, ok: false, error: String(error) });
      console.error(String(error));
      process.exitCode = 1;
    }
  }
} finally {
  await browser.close();
  await mkdir("test-results", { recursive: true });
  await writeFile("test-results/metadata-diagnostics.json", JSON.stringify(results, null, 2));
}
