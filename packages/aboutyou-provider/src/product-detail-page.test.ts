import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import type { BrowserContext, Response } from "playwright";
import { fetchProductDetail, extractProductDetailPayloadFromHtml, PRODUCT_DETAIL_ENDPOINT } from "./index";

const fixture = readFileSync(new URL("./fixtures/product-detail-initial-state.html", import.meta.url), "utf8");
const payload = extractProductDetailPayloadFromHtml(fixture)!;

function setup(options: { html?: string; status?: number; rpcStatus?: number; redirect?: boolean; silent?: boolean } = {}) {
  const listeners: Record<string, (value: never) => void> = {};
  const response = (url: string, status: number) => ({
    url: () => url, status: () => status, ok: () => status === 200,
    headers: () => ({ "content-type": "text/html" }),
    request: () => ({ resourceType: () => "fetch" }),
    body: async () => Buffer.from([0, 0, 0, 0, 2, 8, 1])
  }) as unknown as Response;
  const page = {
    on: vi.fn((event, callback) => { listeners[event] = callback; }),
    goto: vi.fn(async () => {
      if (!options.silent) {
        listeners.response?.(response("https://assets.aboutstatic.com/assets/service.grpc-test.js", 200) as never);
        listeners.response?.(response(`https://tadarida-web.aboutyou.com/${PRODUCT_DETAIL_ENDPOINT}`, options.rpcStatus ?? 200) as never);
      }
      return response("https://www.aboutyou.lt/p/test-123", options.status ?? 200);
    }),
    content: vi.fn(async () => options.html ?? "<html></html>"),
    url: vi.fn(() => options.redirect ? "https://www.aboutyou.lt/b/shop/test" : "https://www.aboutyou.lt/p/test-123"),
    waitForURL: vi.fn(() => options.redirect ? Promise.resolve() : new Promise(() => {})),
    evaluate: vi.fn(async (_script: string) => payload),
    close: vi.fn(async () => {})
  };
  return { page, context: { newPage: async () => page } as unknown as BrowserContext };
}

describe("product detail source loading", () => {
  it("decodes a network payload when SSR has no GetProductBulk", async () => {
    const { page, context } = setup();
    const result = await fetchProductDetail(context, "https://www.aboutyou.lt/p/test-123");
    expect(result.mode).toBe("network");
    expect(result.extraction.sourceProductId).toBeTruthy();
    expect(result.extraction.metadata.sections).toHaveLength(4);
    expect(page.evaluate.mock.calls[0]?.[0]).toContain('"bytes":[8,1]');
    expect(page.close).toHaveBeenCalledOnce();
  });

  it("keeps the SSR path without requiring a network response", async () => {
    const { page, context } = setup({ html: fixture, silent: true });
    expect((await fetchProductDetail(context, "https://www.aboutyou.lt/p/test-123")).mode).toBe("html");
    expect(page.evaluate).not.toHaveBeenCalled();
  });

  it.each([403, 429, 503])("preserves RPC HTTP %s instead of parsing it", async (rpcStatus) => {
    const { page, context } = setup({ rpcStatus });
    expect((await fetchProductDetail(context, "https://www.aboutyou.lt/p/test-123")).status).toBe(rpcStatus);
    expect(page.evaluate).not.toHaveBeenCalled();
  });

  it("returns a client redirect so the worker can classify unavailable products", async () => {
    const { context } = setup({ redirect: true, silent: true });
    expect((await fetchProductDetail(context, "https://www.aboutyou.lt/p/test-123")).finalUrl).toContain("/b/shop/");
  });

  it("closes the page when the expected response never arrives", async () => {
    const { page, context } = setup({ silent: true });
    const onFailure = vi.fn(async () => {});
    await expect(fetchProductDetail(context, "https://www.aboutyou.lt/p/test-123", 10, { onFailure })).rejects.toThrow("product_detail_request_timeout");
    expect(onFailure).toHaveBeenCalledWith(page, expect.objectContaining({ message: "product_detail_request_timeout" }));
    expect(page.close).toHaveBeenCalledOnce();
  });
});
