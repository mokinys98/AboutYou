import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { describe, expect, it, vi } from "vitest";

// Execute the real userscript functions, with deterministic transport and state.
const source = ts.createSourceFile("collector.js", readFileSync(new URL("../../../aboutyou-price-sort.user.js", import.meta.url), "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
function implementation(name: string): string {
  let found = "";
  function visit(node: ts.Node) {
    if (ts.isFunctionDeclaration(node) && node.name?.text === name) found = node.getText(source);
    ts.forEachChild(node, visit);
  }
  visit(source);
  if (!found) throw new Error(`Missing collector function: ${name}`);
  return found;
}

function harness(overrides: Record<string, unknown> = {}) {
  const state = {
    products: new Map([["1", { productId: "1" }]]), collectionTarget: 10,
    loadingAll: false, stopLoading: false, cards: [],
    stream: { nextState: new Uint8Array([1]), total: 10, pages: 0, directError: "", exhausted: false, networkInitialized: true, fallbackComplete: false, rateLimited: false, stopped: false }
  };
  const context = {
    STATE: state, Uint8Array, AbortController, setTimeout, clearTimeout,
    DIRECT_REQUEST_TIMEOUT_MS: 10, DIRECT_ALL_MAX_PAGES: 200,
    AUTOMATION_MODE: false, recordDiagnostic: vi.fn(),
    parseInitialState: vi.fn(), scanCards: vi.fn(), sleep: async () => {},
    renderResults: vi.fn(), updateStatus: vi.fn(), safeDiagnosticError: String,
    collectProductTiles: (items: unknown, visit: (item: unknown) => void) => (Array.isArray(items) ? items : [items]).forEach(visit),
    productFromTile: (item: unknown) => item,
    upsertProduct: (item: { productId: string }) => state.products.set(item.productId, item),
    rememberProductStreamState: (data: { nextState?: Uint8Array }) => { if (data.nextState?.length) state.stream.nextState = new Uint8Array(data.nextState); },
    ...overrides
  };
  const api = runInNewContext([
    implementation("collectStreamItems"), implementation("loadProductsFast"), implementation("collectionSnapshot"), implementation("fetchWithTimeout"),
    "({ loadProductsFast, collectionSnapshot, fetchWithTimeout })"
  ].join("\n"), context);
  return { state, context, api };
}

describe("userscript stream reliability", () => {
  it("does not report three duplicate pages as exhausted", async () => {
    const fetchPage = vi.fn(async () => ({ items: [{ productId: "1" }], nextState: new Uint8Array([2]) }));
    const { api, state } = harness({ fetchNextProductStreamPage: fetchPage });
    await api.loadProductsFast(10);
    expect(fetchPage).toHaveBeenCalledTimes(3);
    expect(state.stream.exhausted).toBe(false);
    expect(api.collectionSnapshot().complete).toBe(false);
  });
  it("does not accept premature stream exhaustion when total is known", async () => {
    const { api } = harness({ fetchNextProductStreamPage: async () => ({ items: [], nextState: new Uint8Array() }) });
    await api.loadProductsFast(10);
    expect(api.collectionSnapshot().complete).toBe(false);
    expect(api.collectionSnapshot().terminationReason).toBe("stream-exhausted");
  });
  it("accepts a small initial catalog without requesting another page", async () => {
    const fetchPage = vi.fn();
    const { api, state } = harness({ fetchNextProductStreamPage: fetchPage });
    state.stream.total = 1;
    state.stream.nextState = new Uint8Array();
    await api.loadProductsFast(100);
    expect(fetchPage).not.toHaveBeenCalled();
    expect(api.collectionSnapshot().complete).toBe(true);
    expect(api.collectionSnapshot().terminationReason).toBe("target-reached");
  });
  it("does not retry rate-limited stream requests", async () => {
    const error = Object.assign(new Error("HTTP 429"), { status: 429 });
    const fetchPage = vi.fn(async () => { throw error; });
    const { api } = harness({ fetchNextProductStreamPage: fetchPage });
    await expect(api.loadProductsFast(10)).rejects.toBe(error);
    expect(fetchPage).toHaveBeenCalledTimes(1);
  });
  it("keeps the request timeout active during body consumption", async () => {
    const { api } = harness({ fetch: async (_url: string, init: { signal: AbortSignal }) => ({
      status: 200,
      text: () => new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(new Error("body aborted"))))
    }) });
    await expect(api.fetchWithTimeout("https://example.test", {}, "test", (response: { text: () => Promise<string> }) => response.text())).rejects.toThrow("body aborted");
  });
});
