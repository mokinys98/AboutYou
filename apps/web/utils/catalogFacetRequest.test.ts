import { describe, expect, it } from "vitest";
import { CatalogFacetRequestCache } from "./catalogFacetRequest";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

describe("catalog facet request cache", () => {
  it("expires memory entries after the five-minute TTL", () => {
    const cache = new CatalogFacetRequestCache<string>(5 * 60 * 1000);
    cache.set("color=blue", "facets", 1_000);

    expect(cache.get("color=blue", 1_000 + 5 * 60 * 1000)).toBe("facets");
    expect(cache.get("color=blue", 1_001 + 5 * 60 * 1000)).toBeUndefined();
  });

  it("prunes expired keys on write without reading those keys", () => {
    const cache = new CatalogFacetRequestCache<string>(100);
    cache.set("old-a", "A", 1_000);
    cache.set("old-b", "B", 1_001);
    expect(cache.size).toBe(2);

    cache.set("fresh", "C", 1_102);

    expect(cache.size).toBe(1);
    expect(cache.get("fresh", 1_102)).toBe("C");
  });

  it("coalesces concurrent requests for the same key", async () => {
    const cache = new CatalogFacetRequestCache<string>(300_000);
    const pending = deferred<string>();
    let calls = 0;
    const loader = () => { calls++; return pending.promise; };

    const first = cache.request("same", loader);
    const second = cache.request("same", loader);
    expect(second).toBe(first);
    expect(calls).toBe(1);
    pending.resolve("value");
    await expect(first.promise).resolves.toBe("value");
    expect(cache.get("same")).toBe("value");
  });

  it("keeps different keys independent", async () => {
    const cache = new CatalogFacetRequestCache<string>(300_000);
    const first = deferred<string>();
    const second = deferred<string>();
    const a = cache.request("a", () => first.promise);
    const b = cache.request("b", () => second.promise);

    expect(a).not.toBe(b);
    first.resolve("A");
    second.resolve("B");
    await Promise.all([a.promise, b.promise]);
    expect(cache.get("a")).toBe("A");
    expect(cache.get("b")).toBe("B");
  });

  it("does not repopulate cache when a response arrives after invalidation", async () => {
    const cache = new CatalogFacetRequestCache<string>(300_000);
    const oldResponse = deferred<string>();
    const request = cache.request("same", () => oldResponse.promise);
    cache.invalidate();
    oldResponse.resolve("stale");

    await expect(request.promise).resolves.toBe("stale");
    expect(cache.get("same")).toBeUndefined();
    expect(request.valid).toBe(false);
  });

  it("does not replace an existing cache entry when a refresh fails", async () => {
    const cache = new CatalogFacetRequestCache<string>(300_000);
    cache.set("same", "last-good");
    const request = cache.request("same", async () => { throw new Error("network failure"); }, true);

    await expect(request.promise).rejects.toThrow("network failure");
    expect(cache.get("same")).toBe("last-good");
  });
});
