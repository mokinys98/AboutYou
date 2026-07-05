import type { Page, Response } from "playwright";
import { fileURLToPath } from "node:url";
import { ProductSchema, cents, isAllowedAboutYouUrl, normalizeColor, normalizeColorShade, type Product } from "@catalog/shared";

const PRODUCT_STREAM_PATH = "aysa_api.services.category_page.v1.stream.CategoryStreamService/GetProductStreamV2";

export class AboutYouRateLimitError extends Error {
  override name = "AboutYouRateLimitError";
}

export interface CollectionResult {
  products: Product[];
  pages: number;
  expectedTotal: number | null;
  mode: "direct-stream" | "scroll-fallback" | "initial-state" | "initial-state+scroll";
  complete: boolean;
}

export interface CollectionProgress {
  products: number;
  expectedTotal: number | null;
  pages: number;
  mode: CollectionResult["mode"];
}

export interface ColorEnrichmentProgress {
  processed: number;
  total: number;
  found: number;
}

export interface ColorEnrichmentResult {
  products: Product[];
  attempted: number;
  found: number;
}

type RawProduct = {
  externalId: string;
  name: string;
  brand: string;
  productUrl: string;
  imageUrls: string[];
  colorOriginal: string | null;
  categories: string[];
  sizes?: string[];
  otherSizes?: string[];
  materials?: string[];
  patterns?: string[];
  features?: string[];
  styles?: string[];
  productTypes?: string[];
  currentPrice: number | null;
  originalPrice: number | null;
  sourceLpl30: number | null;
};

export function decodeGrpcWebFrames(bytes: Uint8Array): Uint8Array {
  if (bytes.length < 5) return bytes;
  const chunks: Uint8Array[] = [];
  let offset = 0;
  while (offset + 5 <= bytes.length) {
    const flags = bytes[offset] ?? 0;
    const length = (bytes[offset + 1] ?? 0) * 16777216 + (bytes[offset + 2] ?? 0) * 65536 +
      (bytes[offset + 3] ?? 0) * 256 + (bytes[offset + 4] ?? 0);
    offset += 5;
    if (offset + length > bytes.length) break;
    if ((flags & 128) === 0) chunks.push(bytes.slice(offset, offset + length));
    offset += length;
  }
  const output = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let position = 0;
  for (const chunk of chunks) { output.set(chunk, position); position += chunk.length; }
  return output;
}

export function normalizeRawProduct(raw: RawProduct): Product | null {
  const parsed = ProductSchema.safeParse({
    ...raw,
    colorFamily: normalizeColor(raw.colorOriginal),
    colorShade: normalizeColorShade(raw.colorOriginal),
    currency: "EUR"
  });
  return parsed.success ? parsed.data : null;
}

export function extractColorFromProductHtml(html: string): string | null {
  const scriptPattern = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  for (const match of html.matchAll(scriptPattern)) {
    if (!/\btype\s*=\s*["']application\/ld\+json["']/i.test(match[1] ?? "")) continue;
    try {
      const color = findStructuredColor(JSON.parse(match[2] ?? ""));
      if (color) return color;
    } catch { /* ignore unrelated or malformed structured data */ }
  }

  const selected = html.match(/data-testid=["']productColorInfoSelectedOptionName["'][^>]*>([\s\S]*?)<\/span>/i)?.[1];
  if (selected) {
    const color = decodeHtml(selected.replace(/<[^>]+>/g, " ")).trim();
    if (color) return color;
  }

  const colorLabel = html.match(/"colorLabel"\s*:\s*"((?:\\.|[^"\\])*)"/i)?.[1];
  if (colorLabel) {
    try { return JSON.parse(`"${colorLabel}"`); }
    catch { /* ignore malformed JSON string */ }
  }
  return null;
}

export async function enrichMissingProductColors(
  page: Page,
  products: Product[],
  options: {
    limit?: number;
    concurrency?: number;
    delayMs?: number;
    timeoutMs?: number;
    onProgress?: (progress: ColorEnrichmentProgress) => void;
  } = {}
): Promise<ColorEnrichmentResult> {
  const limit = Math.max(0, Math.min(options.limit ?? 100, products.length));
  const missingIndexes = products.flatMap((product, index) => product.colorOriginal ? [] : [index]).slice(0, limit);
  if (!missingIndexes.length) return { products, attempted: 0, found: 0 };

  const enriched = [...products];
  const concurrency = Math.max(1, Math.min(options.concurrency ?? 1, 12, missingIndexes.length));
  const delayMs = Math.max(0, options.delayMs ?? 750);
  let cursor = 0;
  let processed = 0;
  let found = 0;
  let nextRequestAt = Date.now();
  const report = () => options.onProgress?.({ processed, total: missingIndexes.length, found });
  const waitForRequestSlot = async () => {
    const now = Date.now();
    const scheduledAt = Math.max(now, nextRequestAt);
    nextRequestAt = scheduledAt + delayMs;
    if (scheduledAt > now) await new Promise((resolve) => setTimeout(resolve, scheduledAt - now));
  };

  const worker = async () => {
    while (cursor < missingIndexes.length) {
      const productIndex = missingIndexes[cursor++];
      if (productIndex === undefined) break;
      const product = enriched[productIndex];
      if (!product) continue;
      try {
        await waitForRequestSlot();
        const response = await page.context().request.get(product.productUrl, {
          failOnStatusCode: false,
          headers: { accept: "text/html,application/xhtml+xml" },
          timeout: options.timeoutMs ?? 20_000
        });
        if (response.ok()) {
          const colorOriginal = extractColorFromProductHtml(await response.text());
          if (colorOriginal) {
            enriched[productIndex] = {
              ...product,
              colorOriginal,
              colorFamily: normalizeColor(colorOriginal),
              colorShade: normalizeColorShade(colorOriginal)
            };
            found += 1;
          }
        }
      } catch { /* a failed detail page must not fail the catalog sync */ }
      processed += 1;
      if (processed === missingIndexes.length || processed % 25 === 0) report();
    }
  };

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  return { products: enriched, attempted: missingIndexes.length, found };
}

function findStructuredColor(value: unknown): string | null {
  if (!value || typeof value !== "object") return null;
  if (!Array.isArray(value)) {
    const color = (value as Record<string, unknown>).color;
    if (typeof color === "string" && color.trim()) return color.trim();
  }
  for (const child of Array.isArray(value) ? value : Object.values(value)) {
    const color = findStructuredColor(child);
    if (color) return color;
  }
  return null;
}

function decodeHtml(value: string): string {
  return value
    .replace(/&quot;/gi, '"').replace(/&#39;|&apos;/gi, "'").replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<").replace(/&gt;/gi, ">")
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Number(code)))
    .replace(/&#x([\da-f]+);/gi, (_, code: string) => String.fromCodePoint(Number.parseInt(code, 16)));
}

export async function collectAboutYouTarget(
  page: Page,
  url: string,
  options: {
    maxProducts?: number;
    maxScrollRounds?: number;
    timeoutMs?: number;
    progressIntervalMs?: number;
    onProgress?: (progress: CollectionProgress) => void;
  } = {}
): Promise<CollectionResult> {
  if (!isAllowedAboutYouUrl(url)) throw new Error(`Neleistinas ABOUT YOU URL: ${url}`);
  const maxProducts = Math.min(options.maxProducts ?? 10_000, 10_000);
  const maxScrollRounds = options.maxScrollRounds ?? 180;

  await page.addInitScript({
    path: fileURLToPath(new URL("../../../aboutyou-price-sort.user.js", import.meta.url))
  });

  const initialResponse = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60_000 });
  await assertAboutYouPageAvailable(page, initialResponse);
  await page.waitForTimeout(1_200);

  try {
    return await collectFromDirectStream(page, maxProducts, options);
  } catch (error) {
    options.onProgress?.({ products: 0, expectedTotal: null, pages: 0, mode: "scroll-fallback" });
    console.warn(`[aboutyou-provider] Tiesioginis srautas nepavyko, naudojamas DOM fallback: ${safeError(error)}`);
    const fallbackResponse = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60_000 });
    await assertAboutYouPageAvailable(page, fallbackResponse);
    await page.waitForTimeout(1_200);
  }

  const initial = await page.evaluate(({ streamPath }) => {
    const tiles: unknown[] = [];
    let total: number | null = null;
    for (const script of document.querySelectorAll('script[data-tadarida-initial-state="true"]')) {
      try {
        const entries = JSON.parse(script.textContent || "[]", (key: string, value: unknown) => {
          const candidate = value as { __type?: string; data?: unknown[] } | null;
          if ((candidate?.__type === "_Uint8Array_" || key === "nextState") && Array.isArray(candidate?.data)) {
            return new Uint8Array(candidate.data as number[]);
          }
          return value;
        }) as Array<[string, unknown]>;
        for (const [key, payload] of entries) {
          if (!String(key).includes(streamPath)) continue;
          const wrapper = payload as { data?: Record<string, unknown> };
          const data = wrapper?.data ?? payload;
          const pagination = (data as { pagination?: { total?: number } })?.pagination;
          if (Number.isFinite(pagination?.total)) total = pagination!.total!;
          const pending: unknown[] = [data];
          while (pending.length) {
            const value = pending.pop();
            if (!value || typeof value !== "object") continue;
            const object = value as Record<string, unknown>;
            const productTile = object.productTile as Record<string, unknown> | undefined;
            if (productTile?.productId) tiles.push(productTile);
            const type = object.type as Record<string, unknown> | undefined;
            const section = type?.productSection as Record<string, unknown> | undefined;
            const nested = section?.productTile as Record<string, unknown> | undefined;
            if (nested?.productId) tiles.push(nested);
            pending.push(...(Array.isArray(value) ? value : Object.values(object)));
          }
        }
      } catch { /* ignore malformed state */ }
    }
    return { tiles, total };
  }, { streamPath: PRODUCT_STREAM_PATH });

  const raw = new Map<string, RawProduct>();
  for (const tile of initial.tiles) {
    const product = rawFromTile(tile as Record<string, unknown>, url);
    if (product) raw.set(product.externalId, product);
  }

  let stable = 0;
  let previous = raw.size;
  let rounds = 0;
  while (raw.size < maxProducts && stable < 6 && rounds < maxScrollRounds) {
    rounds += 1;
    const domProducts = await page.evaluate(() => Array.from(document.querySelectorAll<HTMLAnchorElement>('a[href*="/p/"]')).map((anchor) => {
      const card = anchor.closest<HTMLElement>("article, li") ?? anchor.parentElement;
      const image = card?.querySelector<HTMLImageElement>("img");
      const text = card?.innerText ?? "";
      return { href: anchor.href, name: image?.alt || anchor.getAttribute("aria-label") || "", image: image?.currentSrc || image?.src || "", text };
    }));
    for (const item of domProducts) {
      const id = item.href.match(/-(\d+)(?:[?#]|$)/)?.[1];
      const currentPrice = cents(item.text);
      if (!id || currentPrice === null) continue;
      const existing = raw.get(id);
      raw.set(id, {
        externalId: id,
        name: existing?.name || item.name || `Produktas ${id}`,
        brand: existing?.brand || "",
        productUrl: item.href,
        imageUrls: existing?.imageUrls.length ? existing.imageUrls : item.image ? [item.image] : [],
        colorOriginal: existing?.colorOriginal ?? null,
        categories: existing?.categories.length ? existing.categories : [],
        sizes: existing?.sizes ?? [],
        otherSizes: existing?.otherSizes ?? [],
        materials: existing?.materials ?? [],
        patterns: existing?.patterns ?? [],
        features: existing?.features ?? [],
        styles: existing?.styles ?? [],
        productTypes: existing?.productTypes ?? productTypeFromName(item.name),
        currentPrice: existing?.currentPrice ?? currentPrice,
        originalPrice: existing?.originalPrice ?? null,
        sourceLpl30: existing?.sourceLpl30 ?? null
      });
    }
    stable = raw.size === previous ? stable + 1 : 0;
    previous = raw.size;
    if (initial.total && raw.size >= initial.total) break;
    await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
    await page.waitForTimeout(650);
  }

  const products = Array.from(raw.values()).map(normalizeRawProduct).filter((item): item is Product => item !== null).slice(0, maxProducts);
  const targetTotal = Math.min(maxProducts, initial.total ?? maxProducts);
  return {
    products,
    pages: Math.max(1, rounds),
    expectedTotal: initial.total,
    mode: rounds ? "initial-state+scroll" : "initial-state",
    complete: raw.size >= targetTotal || (initial.total === null && stable >= 6)
  };
}

type BrowserCollection = {
  products: Array<{
    productId?: string | number;
    name?: string;
    brand?: string;
    url?: string;
    imageUrls?: string[];
    colorOriginal?: string | null;
    sizes?: string[];
    otherSizes?: string[];
    materials?: string[];
    patterns?: string[];
    features?: string[];
    styles?: string[];
    productTypes?: string[];
    currentPrice?: number | null;
    originalPrice?: number | null;
    lplPrice?: number | null;
  }>;
  productCount: number;
  expectedTotal: number | null;
  pages: number;
  loading: boolean;
  mode: "direct-stream" | "scroll-fallback";
  complete: boolean;
  error: string | null;
};

async function collectFromDirectStream(
  page: Page,
  maxProducts: number,
  options: {
    timeoutMs?: number;
    progressIntervalMs?: number;
    onProgress?: (progress: CollectionProgress) => void;
  }
): Promise<CollectionResult> {
  await page.waitForFunction(() => Boolean((window as unknown as {
    __ABOUTYOU_CATALOG_COLLECTOR__?: unknown;
  }).__ABOUTYOU_CATALOG_COLLECTOR__), undefined, { timeout: 10_000 });

  const collection = page.evaluate(async (limit) => {
    const api = (window as unknown as {
      __ABOUTYOU_CATALOG_COLLECTOR__: { collect: (target: number) => Promise<BrowserCollection> };
    }).__ABOUTYOU_CATALOG_COLLECTOR__;
    return api.collect(limit);
  }, maxProducts);
  const timeoutMs = options.timeoutMs ?? 8 * 60_000;
  const progressIntervalMs = options.progressIntervalMs ?? 5_000;
  const progress = setInterval(() => {
    void page.evaluate(() => {
      const api = (window as unknown as {
        __ABOUTYOU_CATALOG_COLLECTOR__?: { snapshot: () => BrowserCollection };
      }).__ABOUTYOU_CATALOG_COLLECTOR__;
      return api?.snapshot();
    }).then((snapshot) => {
      if (snapshot) options.onProgress?.({
        products: snapshot.productCount,
        expectedTotal: snapshot.expectedTotal,
        pages: snapshot.pages,
        mode: snapshot.mode
      });
    }).catch(() => undefined);
  }, progressIntervalMs);
  progress.unref();

  let result: BrowserCollection;
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    result = await Promise.race([
      collection,
      new Promise<never>((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`Produktų rinkimas viršijo ${Math.round(timeoutMs / 1_000)} s timeout'ą.`)), timeoutMs);
        timeout.unref();
      })
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
    clearInterval(progress);
  }

  const raw = result.products.map((item): RawProduct | null => {
    if (!item.productId || !item.url || item.currentPrice === null || item.currentPrice === undefined) return null;
    return {
      externalId: String(item.productId),
      name: item.name || `Produktas ${item.productId}`,
      brand: item.brand || "",
      productUrl: item.url,
      imageUrls: item.imageUrls ?? [],
      colorOriginal: item.colorOriginal ?? null,
      categories: [],
      sizes: item.sizes ?? [],
      otherSizes: item.otherSizes ?? [],
      materials: item.materials ?? [],
      patterns: item.patterns ?? [],
      features: item.features ?? [],
      styles: item.styles ?? [],
      productTypes: item.productTypes?.length ? item.productTypes : productTypeFromName(item.name ?? ""),
      currentPrice: item.currentPrice,
      originalPrice: item.originalPrice ?? null,
      sourceLpl30: item.lplPrice ?? null
    };
  }).filter((item): item is RawProduct => item !== null);
  const products = raw.map(normalizeRawProduct).filter((item): item is Product => item !== null).slice(0, maxProducts);
  if (result.error) console.warn(`[aboutyou-provider] Rinkimo fallback priežastis: ${result.error.slice(0, 500)}`);
  if (products.length === 0) throw new Error(result.error || "Tiesioginis produkto srautas negrąžino produktų.");
  return {
    products,
    pages: Math.max(1, result.pages),
    expectedTotal: result.expectedTotal,
    mode: result.mode,
    complete: result.complete
  };
}

function safeError(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).slice(0, 500);
}

function rawFromTile(tile: Record<string, unknown>, baseUrl: string): RawProduct | null {
  const productId = tile.productId;
  if (typeof productId !== "number" && typeof productId !== "string") return null;
  const price = object(tile.price);
  const priceV2 = object(tile.priceV2);
  const tracker = object(price?.tracker) ?? object(priceV2?.tracker);
  const finalPrice = object(priceV2?.finalPrice);
  const priceLabel = object(finalPrice?.priceLabel);
  const link = object(tile.link);
  const productTracker = object(tile.productTracker);
  const brandTracker = object(tile.brandTracker);
  const imageUrls = findImageUrls(tile);
  const colorOriginal = findString(tile, ["colorLabel", "colorName", "color", "displayColor", "baseColor"]);
  const currentPrice = number(price?.price && object(price.price)?.amount) ?? number(tracker?.price) ?? cents(string(priceLabel?.text));
  const originalPrice = number(tracker?.fullPrice) ?? cents(string(priceV2?.original && object(priceV2.original)?.text));
  const lpl = object(priceV2?.lpl30d);
  const lplValue = object(lpl?.value);
  const sourceLpl30 = cents(string(lplValue?.text)) ?? cents(string(price?.lpl30));
  const relative = string(link?.url) || string(productTracker?.linkTarget);
  if (!relative || currentPrice === null) return null;
  return {
    externalId: String(productId),
    name: string(productTracker?.productName) || `Produktas ${productId}`,
    brand: string(tile.brandName) || string(brandTracker?.name),
    productUrl: new URL(relative, baseUrl).href,
    imageUrls,
    colorOriginal: colorOriginal || null,
    categories: findStrings(tile, ["categoryName", "categoryNames", "categories"]),
    sizes: findStrings(tile, ["availableSizes", "sizeLabels", "sizes"]),
    otherSizes: findStrings(tile, ["otherSizes", "specialSizes", "sizeGroups"]),
    materials: findStrings(tile, ["material", "materials", "materialName", "materialComposition"]),
    patterns: findStrings(tile, ["pattern", "patterns", "patternName"]),
    features: findStrings(tile, ["features", "productFeatures", "attributes"]),
    styles: findStrings(tile, ["style", "styles", "styleName"]),
    productTypes: findStrings(tile, ["productType", "productTypes", "productTypeName"]).length
      ? findStrings(tile, ["productType", "productTypes", "productTypeName"])
      : productTypeFromName(string(productTracker?.productName)),
    currentPrice, originalPrice, sourceLpl30
  };
}

function object(value: unknown): Record<string, unknown> | null { return value && typeof value === "object" ? value as Record<string, unknown> : null; }
function string(value: unknown): string { return typeof value === "string" ? value : ""; }
function number(value: unknown): number | null { return typeof value === "number" && Number.isFinite(value) ? Math.round(value) : null; }

async function assertAboutYouPageAvailable(page: Page, response: Response | null): Promise<void> {
  const status = response?.status() ?? 0;
  const title = await page.title().catch(() => "");
  if (status === 429 || status === 403 || /access denied|rate limit/i.test(title)) {
    throw new AboutYouRateLimitError(
      `ABOUT YOU laikinai riboja užklausas (HTTP ${status || "nežinomas"}, Cloudflare 1015). ` +
      "Sustabdykite sync ir bandykite vėliau; kartotiniai bandymai blokavimą pratęsia."
    );
  }
  if (status >= 400) throw new Error(`ABOUT YOU katalogas grąžino HTTP ${status}.`);
}

function findString(value: unknown, keys: string[]): string {
  if (!value || typeof value !== "object") return "";
  const objectValue = value as Record<string, unknown>;
  for (const key of keys) if (typeof objectValue[key] === "string") return objectValue[key] as string;
  for (const child of Object.values(objectValue)) { const found = findString(child, keys); if (found) return found; }
  return "";
}

function findStrings(value: unknown, keys: string[]): string[] {
  const wanted = new Set(keys);
  const values = new Set<string>();
  const add = (item: unknown): void => {
    if (typeof item === "string") {
      const text = item.replace(/\s+/g, " ").trim();
      if (text && text.length <= 100 && !/^https?:/i.test(text)) values.add(text);
    } else if (Array.isArray(item)) item.forEach(add);
    else if (item && typeof item === "object") {
      const objectItem = item as Record<string, unknown>;
      add(objectItem.label ?? objectItem.name ?? objectItem.value ?? objectItem.text);
    }
  };
  const visit = (item: unknown): void => {
    if (!item || typeof item !== "object") return;
    for (const [key, child] of Object.entries(item as Record<string, unknown>)) {
      if (wanted.has(key)) add(child);
      if (child && typeof child === "object") visit(child);
    }
  };
  visit(value);
  return Array.from(values).slice(0, 30);
}

function productTypeFromName(name: string): string[] {
  const value = name.replace(/\s+[„“'\"].*$/, "").trim();
  return value && value.length <= 80 ? [value] : [];
}

function findImageUrls(value: unknown): string[] {
  const urls = new Set<string>();
  const visit = (item: unknown): void => {
    if (typeof item === "string" && /^https:\/\//.test(item) && /\.(?:jpe?g|webp|avif)(?:\?|$)/i.test(item)) urls.add(item);
    else if (Array.isArray(item)) item.forEach(visit);
    else if (item && typeof item === "object") Object.values(item as Record<string, unknown>).forEach(visit);
  };
  visit(value);
  return Array.from(urls).slice(0, 6);
}
