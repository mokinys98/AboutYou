import { afterEach, describe, expect, it, vi } from "vitest";
import type { Page } from "playwright";
import { collectAboutYouTarget } from "./index";

const url = "https://www.aboutyou.lt/c/vyrams/drabuziai-20290";
const product = { productId: "123", name: "Shirt", url: "https://www.aboutyou.lt/p/brand/shirt-123", currentPrice: 1999 };
function pageWith(result: Record<string, unknown>, pending = false) {
  const evaluate = vi.fn(async (fn: unknown, argument: unknown) => {
    const code = String(fn);
    if (code.includes("api.collect(limit,")) return pending ? new Promise(() => {}) : result;
    if (code.includes("snapshot: api.snapshot()")) return { snapshot: { ...result, loading: true }, diagnostics: [] };
    if (code.includes("api?.drainDiagnostics()")) return [];
    return argument;
  });
  return {
    addInitScript: vi.fn(), on: vi.fn(), off: vi.fn(), goto: vi.fn(async () => ({ status: () => 200 })),
    title: vi.fn(async () => "ABOUT YOU"), url: () => url, waitForTimeout: vi.fn(),
    waitForFunction: vi.fn(), evaluate
  } as unknown as Page;
}
const result = {
  products: [product], productCount: 1, pages: 1, expectedTotal: 1, mode: "direct-stream",
  complete: true, terminationReason: "target-reached", error: null, loading: false
};
afterEach(() => vi.useRealTimers());

describe("provider collection boundaries", () => {
  it("passes the configured 15000 limit to the browser instead of silently capping it", async () => {
    const page = pageWith(result);
    await collectAboutYouTarget(page, url, { maxProducts: 15000 });
    expect(vi.mocked(page.evaluate).mock.calls.some(([fn, arg]) => String(fn).includes("api.collect(limit,") && (arg as { limit: number }).limit === 15000)).toBe(true);
  });
  it("keeps direct collection on errors and only enables fallback explicitly", async () => {
    const page = pageWith({ ...result, products: [], error: "module missing" });
    await expect(collectAboutYouTarget(page, url)).rejects.toThrow("module missing");
    expect(page.goto).toHaveBeenCalledTimes(1);
    expect(page.off).toHaveBeenCalledWith("response", expect.any(Function));
  });
  it("feeds service chunks discovered after navigation into the running collector", async () => {
    const page = pageWith(result);
    await collectAboutYouTarget(page, url, { allowDomFallback: true });
    const calls = vi.mocked(page.on).mock.calls as unknown as Array<[string, (response: { url: () => string }) => void]>;
    const listener = calls.find(([event]) => event === "response")?.[1];
    expect(listener).toBeDefined();
    listener!({ url: () => "https://assets.aboutstatic.com/assets/service.grpc-lazy-late.js" });
    expect(page.evaluate).toHaveBeenCalledWith(expect.any(Function), "https://assets.aboutstatic.com/assets/service.grpc-lazy-late.js");
    expect(vi.mocked(page.evaluate).mock.calls.some(([fn, arg]) => String(fn).includes("api.collect(limit,") && (arg as { allowDomFallback: boolean }).allowDomFallback)).toBe(true);
  });
  it("does not accept a complete browser result after invalid products are discarded", async () => {
    const page = pageWith({ ...result, products: [product, { ...product, productId: "456", currentPrice: -1 }], expectedTotal: 2, productCount: 2 });
    const collection = await collectAboutYouTarget(page, url);
    expect(collection.products).toHaveLength(1);
    expect(collection.complete).toBe(false);
  });
  it("does not allow production queue workers to silently use DOM scrolling", async () => {
    const page = pageWith({ ...result, mode: "scroll-fallback", error: "stream module missing" });
    await expect(collectAboutYouTarget(page, url, { allowScrollFallback: false })).rejects.toThrow("stream module missing");
  });
  it("preserves the last valid snapshot on timeout without waiting for an unresponsive page", async () => {
    vi.useFakeTimers();
    const page = pageWith({ ...result, expectedTotal: 100 }, true);
    const collection = collectAboutYouTarget(page, url, { timeoutMs: 100, progressIntervalMs: 10 });
    await vi.advanceTimersByTimeAsync(110);
    const actual = await collection;
    expect(actual.products).toHaveLength(1);
    expect(actual.complete).toBe(false);
    expect(actual.terminationReason).toBe("timeout");
    expect(actual.error).toContain("timeout");
  });
});
