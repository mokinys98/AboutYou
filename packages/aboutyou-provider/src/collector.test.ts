import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { describe, expect, it, vi } from "vitest";

// Execute the real userscript functions, with deterministic transport and state.
const source = ts.createSourceFile("collector.js", readFileSync(new URL("../../../aboutyou-price-sort.user.js", import.meta.url), "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
function implementation(name: string): string {
  let found = "";
  function visit(node: ts.Node) {
    if ((ts.isFunctionDeclaration(node) || ts.isClassDeclaration(node)) && node.name?.text === name) found = node.getText(source);
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
    describeStreamItems: () => ({}),
    collectProductTiles: (items: Array<{ productId: string }>, visit: (item: unknown) => void) => items.forEach(visit),
    productFromTile: (item: unknown) => item,
    upsertProduct: (item: { productId: string }) => state.products.set(item.productId, item),
    rememberProductStreamState: (data: { nextState?: Uint8Array }) => { if (data.nextState?.length) state.stream.nextState = new Uint8Array(data.nextState); },
    ...overrides
  };
  const api = runInNewContext([
    implementation("loadProductsFast"), implementation("collectionSnapshot"), implementation("fetchWithTimeout"),
    "({ loadProductsFast, collectionSnapshot, fetchWithTimeout })"
  ].join("\n"), context);
  return { state, context, api };
}

describe("userscript stream reliability", () => {
  it("skips unknown protobuf fields including their length prefix", () => {
    const Reader = runInNewContext(`${implementation("ProtoReader")}; ProtoReader`, { Uint8Array, TextDecoder, DataView });
    const reader = new Reader(new Uint8Array([18, 3, 65, 66, 67, 24, 9]));
    expect(reader.uint32()).toBe(18);
    reader.skipType(2);
    expect(reader.pos).toBe(5);
    expect(reader.uint32()).toBe(24);
    expect(reader.uint32()).toBe(9);
    expect(() => reader.uint32()).toThrow("varint");
  });
  it("fails fast on truncated protobuf fields and unknown wire types", () => {
    const Reader = runInNewContext(`${implementation("ProtoReader")}; ProtoReader`, { Uint8Array, TextDecoder, DataView });
    expect(() => new Reader(new Uint8Array([8, 65])).bytes()).toThrow("Truncated");
    expect(() => new Reader(new Uint8Array([128])).uint32()).toThrow("varint");
    expect(() => new Reader(new Uint8Array([0])).skipType(7)).toThrow("wire type");
  });
  it("does not report three duplicate pages as exhausted", async () => {
    const fetchPage = vi.fn(async () => ({ items: [{ productId: "1" }], nextState: new Uint8Array([2]) }));
    const { api, state } = harness({ fetchNextProductStreamPage: fetchPage });
    await api.loadProductsFast(10);
    expect(fetchPage).toHaveBeenCalledTimes(3);
    expect(state.stream.exhausted).toBe(false);
    expect(api.collectionSnapshot().complete).toBe(false);
  });
  it("uses scrolling only when explicitly allowed after a direct failure", async () => {
    const state = { stream: { usedFallback: false }, products: new Map(), cards: [], stopLoading: false, loadingAll: false };
    let failure = new Error("module discovery failed");
    const scroll = vi.fn(async () => {});
    const load = runInNewContext(`${implementation("loadProducts")}; loadProducts`, {
      STATE: state, AUTOMATION_MODE: true, console: { warn: vi.fn() },
      ensurePageContext: vi.fn(), applyFilter: vi.fn(), updateActiveButtons: vi.fn(),
      updateStatus: vi.fn(), recordDiagnostic: vi.fn(), safeDiagnosticError: String,
      loadProductsFast: async () => { throw failure; },
      loadProductsByScroll: scroll, sleep: async () => {}, scanCards: vi.fn(), renderResults: vi.fn()
    });
    await load(100, false);
    expect(scroll).not.toHaveBeenCalled();
    await load(100, true);
    expect(scroll).toHaveBeenCalledTimes(1);
    failure = Object.assign(new Error("HTTP 429"), { status: 429 });
    await load(100, true);
    expect(scroll).toHaveBeenCalledTimes(1);
    expect(state.stream.usedFallback).toBe(false);
  });
  it("does not accept premature stream exhaustion when total is known", async () => {
    const { api } = harness({ fetchNextProductStreamPage: async () => ({ items: [], nextState: new Uint8Array() }) });
    await api.loadProductsFast(10);
    expect(api.collectionSnapshot().complete).toBe(false);
  });
  it("accepts a small initial catalog without requesting another page", async () => {
    const fetchPage = vi.fn();
    const { api, state } = harness({ fetchNextProductStreamPage: fetchPage });
    state.stream.total = 1;
    state.stream.nextState = new Uint8Array();
    await api.loadProductsFast(100);
    expect(fetchPage).not.toHaveBeenCalled();
    expect(api.collectionSnapshot().complete).toBe(true);
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
