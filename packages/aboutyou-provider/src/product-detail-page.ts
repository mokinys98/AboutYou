import { readFileSync } from "node:fs";
import type { BrowserContext, Response } from "playwright";
import {
  PRODUCT_DETAIL_ENDPOINT, decodeGrpcWebFrames, extractProductDetailFromHtml,
  extractProductDetailFromPayload, type ProductDetailExtraction
} from "./index";

const decoder = readFileSync(new URL("./product-detail-browser.js", import.meta.url), "utf8");

/** Uses the shop's own request and current decoder; no session headers are persisted. */
export async function fetchProductDetail(context: BrowserContext, url: string, timeoutMs = 25_000): Promise<{
  extraction: ProductDetailExtraction; html: string; status: number; finalUrl: string;
  contentType: string | null; mode: "html" | "network";
}> {
  const page = await context.newPage();
  const modules = new Set<string>();
  let resolveResponse!: (response: Response) => void;
  const responseReady = new Promise<Response>((resolve) => { resolveResponse = resolve; });
  page.on("response", (response) => {
    const parsed = new URL(response.url());
    if (parsed.hostname === "assets.aboutstatic.com" && /\/service\.grpc-[^/]+\.js$/.test(parsed.pathname)) {
      modules.add(response.url());
    }
    if (parsed.hostname === "tadarida-web.aboutyou.com" && parsed.pathname === `/${PRODUCT_DETAIL_ENDPOINT}`) {
      resolveResponse(response);
    }
  });
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      (async () => {
        const navigation = await page.goto(url, { waitUntil: "domcontentloaded", timeout: timeoutMs });
        const html = await page.content();
        const extraction = extractProductDetailFromHtml(html);
        const base = {
          html, extraction, status: navigation?.status() ?? 0, finalUrl: page.url(),
          contentType: navigation?.headers()["content-type"] ?? null, mode: "html" as const
        };
        if (base.status >= 400 || extraction.rawPayload) return base;
        // Client-side redirects can signal a removed product despite HTTP 200.
        const response = await Promise.race([
          responseReady,
          page.waitForURL((current) => !current.pathname.startsWith("/p/"), { timeout: timeoutMs }).then(() => null)
        ]);
        if (!response) return { ...base, finalUrl: page.url() };
        if (!response.ok()) return { ...base, status: response.status(), mode: "network" as const };
        const bytes = decodeGrpcWebFrames(await response.body());
        if (!bytes.length) throw new Error("product_detail_response_empty");
        const input = JSON.stringify({ bytes: Array.from(bytes), modules: [...modules].reverse() });
        const payload = await page.evaluate(`(${decoder})(${input})`) as Record<string, unknown>;
        return {
          ...base, finalUrl: page.url(), mode: "network" as const,
          extraction: extractProductDetailFromPayload(payload, html)
        };
      })(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error("product_detail_request_timeout")), timeoutMs);
      })
    ]);
  } finally {
    clearTimeout(timer);
    await page.close();
  }
}
