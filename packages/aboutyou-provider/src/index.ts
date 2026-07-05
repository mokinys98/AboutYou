import type { Page } from "playwright";
import { ProductSchema, cents, isAllowedAboutYouUrl, normalizeColor, type Product } from "@catalog/shared";

const PRODUCT_STREAM_PATH = "aysa_api.services.category_page.v1.stream.CategoryStreamService/GetProductStreamV2";

export interface CollectionResult {
  products: Product[];
  pages: number;
  expectedTotal: number | null;
  mode: "initial-state" | "initial-state+scroll";
}

type RawProduct = {
  externalId: string;
  name: string;
  brand: string;
  productUrl: string;
  imageUrls: string[];
  colorOriginal: string | null;
  categories: string[];
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
    currency: "EUR"
  });
  return parsed.success ? parsed.data : null;
}

export async function collectAboutYouTarget(
  page: Page,
  url: string,
  options: { maxProducts?: number; maxScrollRounds?: number } = {}
): Promise<CollectionResult> {
  if (!isAllowedAboutYouUrl(url)) throw new Error(`Neleistinas ABOUT YOU URL: ${url}`);
  const maxProducts = Math.min(options.maxProducts ?? 10_000, 10_000);
  const maxScrollRounds = options.maxScrollRounds ?? 180;

  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60_000 });
  await page.waitForTimeout(1_200);

  const initial = await page.evaluate(({ streamPath }) => {
    const revive = (key: string, value: unknown) => {
      const candidate = value as { __type?: string; data?: unknown[] } | null;
      if ((candidate?.__type === "_Uint8Array_" || key === "nextState") && Array.isArray(candidate?.data)) {
        return new Uint8Array(candidate.data as number[]);
      }
      return value;
    };
    const tiles: unknown[] = [];
    let total: number | null = null;
    const visit = (value: unknown): void => {
      if (!value || typeof value !== "object") return;
      const object = value as Record<string, unknown>;
      const productTile = object.productTile as Record<string, unknown> | undefined;
      if (productTile?.productId) tiles.push(productTile);
      const type = object.type as Record<string, unknown> | undefined;
      const section = type?.productSection as Record<string, unknown> | undefined;
      const nested = section?.productTile as Record<string, unknown> | undefined;
      if (nested?.productId) tiles.push(nested);
      if (Array.isArray(value)) value.forEach(visit);
      else Object.values(object).forEach(visit);
    };
    for (const script of document.querySelectorAll('script[data-tadarida-initial-state="true"]')) {
      try {
        const entries = JSON.parse(script.textContent || "[]", revive) as Array<[string, unknown]>;
        for (const [key, payload] of entries) {
          if (!String(key).includes(streamPath)) continue;
          const wrapper = payload as { data?: Record<string, unknown> };
          const data = wrapper?.data ?? payload;
          const pagination = (data as { pagination?: { total?: number } })?.pagination;
          if (Number.isFinite(pagination?.total)) total = pagination!.total!;
          visit(data);
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
  return { products, pages: Math.max(1, rounds), expectedTotal: initial.total, mode: rounds ? "initial-state+scroll" : "initial-state" };
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
  const colorOriginal = findString(tile, ["colorName", "color", "displayColor", "baseColor"]);
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
    categories: [], currentPrice, originalPrice, sourceLpl30
  };
}

function object(value: unknown): Record<string, unknown> | null { return value && typeof value === "object" ? value as Record<string, unknown> : null; }
function string(value: unknown): string { return typeof value === "string" ? value : ""; }
function number(value: unknown): number | null { return typeof value === "number" && Number.isFinite(value) ? Math.round(value) : null; }

function findString(value: unknown, keys: string[]): string {
  if (!value || typeof value !== "object") return "";
  const objectValue = value as Record<string, unknown>;
  for (const key of keys) if (typeof objectValue[key] === "string") return objectValue[key] as string;
  for (const child of Object.values(objectValue)) { const found = findString(child, keys); if (found) return found; }
  return "";
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

