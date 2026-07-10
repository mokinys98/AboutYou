import type { APIResponse, Page, Response } from "playwright";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { ProductSchema, cents, isAllowedAboutYouUrl, normalizeColor, normalizeColorShade, type Product } from "@catalog/shared";

const PRODUCT_STREAM_PATH = "aysa_api.services.category_page.v1.stream.CategoryStreamService/GetProductStreamV2";
export const PRODUCT_DETAIL_ENDPOINT = "aysa_api.services.article_detail_page.v1.ArticleDetailService/GetProductBulk";
export const PRODUCT_DETAIL_PARSER_VERSION = 5;

export const productDetailSectionKeys = [
  "size_and_fit", "measurements", "material_composition", "design_and_extras"
] as const;
export type ProductDetailSectionKey = typeof productDetailSectionKeys[number];

export interface ProductDetailItem {
  label: string | null;
  value: string;
  unit: string | null;
  rawText: string;
}

export interface ProductDetailSection {
  key: ProductDetailSectionKey;
  sourceLabel: string;
  status: "present" | "source_absent";
  sourceType: string | null;
  position: number;
  items: ProductDetailItem[];
}

export interface ProductColorOption {
  externalId: string | null;
  label: string;
  url: string | null;
  selected: boolean;
}

export interface ProductSizeOption {
  externalId: string;
  label: string;
  group: string | null;
  selected: boolean;
  selectable: boolean;
  availability: string | null;
}

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

export interface ProductMetadataEnrichmentProgress {
  processed: number;
  total: number;
  foundColors: number;
  foundCategories: number;
}

export interface ProductMetadataEnrichmentResult {
  products: Product[];
  attempted: number;
  refreshed: number;
  refreshedExternalIds: string[];
  foundColors: number;
  foundCategories: number;
  attempts: ProductMetadataAttempt[];
  rateLimited: boolean;
}

export interface ProductMetadataAttempt {
  externalId: string;
  rawPayload: Record<string, unknown> | null;
  payloadHash: string | null;
  sourceEndpoint: string;
  parserVersion: number;
  metadataFound: boolean;
  error: string | null;
  httpStatus: number | null;
  contentType: string | null;
  responseSize: number | null;
  finalUrl: string | null;
  responseHtml: string | null;
}

export type ProductDetailMetadata = {
  colorOriginal: string | null;
  categories: string[];
  imageUrls: string[];
  sizes: string[];
  otherSizes: string[];
  materials: string[];
  patterns: string[];
  features: string[];
  styles: string[];
  productTypes: string[];
  isPremium: boolean;
  sections: ProductDetailSection[];
  colorOptions: ProductColorOption[];
  sizeOptions: ProductSizeOption[];
};

export interface ProductDetailExtraction {
  metadata: ProductDetailMetadata;
  rawPayload: Record<string, unknown> | null;
  payloadHash: string | null;
  sourceProductId: string | null;
  schemaError: string | null;
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
  isPremium?: boolean;
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
  return extractProductMetadataFromHtml(html).colorOriginal;
}

export function extractProductDetailFromHtml(html: string): ProductDetailExtraction {
  const rawPayload = extractProductDetailPayloadFromHtml(html);
  const parsed = rawPayload ? extractProductDetailMetadata(rawPayload) : {
    metadata: emptyProductDetailMetadata(), sourceProductId: null, schemaError: null
  };
  const apiMetadata = parsed.metadata;
  const fallback = extractFallbackMetadataFromHtml(html);
  const metadata: ProductDetailMetadata = {
    colorOriginal: apiMetadata.colorOriginal ?? fallback.colorOriginal,
    categories: preferValues(apiMetadata.categories, fallback.categories),
    imageUrls: preferValues(apiMetadata.imageUrls, fallback.imageUrls),
    sizes: preferValues(apiMetadata.sizes, fallback.sizes),
    otherSizes: preferValues(apiMetadata.otherSizes, fallback.otherSizes),
    materials: preferValues(apiMetadata.materials, fallback.materials),
    patterns: preferValues(apiMetadata.patterns, fallback.patterns),
    features: preferValues(apiMetadata.features, fallback.features),
    styles: preferValues(apiMetadata.styles, fallback.styles),
    productTypes: preferValues(apiMetadata.productTypes, fallback.productTypes),
    isPremium: apiMetadata.isPremium || fallback.isPremium,
    sections: apiMetadata.sections,
    colorOptions: apiMetadata.colorOptions,
    sizeOptions: apiMetadata.sizeOptions
  };
  return {
    metadata, rawPayload, payloadHash: rawPayload ? hashProductDetailPayload(rawPayload) : null,
    sourceProductId: parsed.sourceProductId,
    schemaError: parsed.schemaError
  };
}

export function extractProductMetadataFromHtml(html: string): ProductDetailMetadata {
  return extractProductDetailFromHtml(html).metadata;
}

export function extractProductDetailPayloadFromHtml(html: string): Record<string, unknown> | null {
  const scriptPattern = /<script\b[^>]*\bdata-tadarida-initial-state\s*=\s*["']true["'][^>]*>([\s\S]*?)<\/script>/gi;
  for (const match of html.matchAll(scriptPattern)) {
    try {
      const entries = JSON.parse(decodeHtml(match[1] ?? "")) as unknown;
      if (!Array.isArray(entries)) continue;
      for (const entry of entries) {
        if (!Array.isArray(entry) || typeof entry[0] !== "string") continue;
        const key = decodeInitialStateKey(entry[0]);
        if (!key.startsWith(PRODUCT_DETAIL_ENDPOINT)) continue;
        const wrapper = object(entry[1]);
        const payload = object(wrapper?.data) ?? wrapper;
        if (!payload) continue;
        // Response trailers contain transport and A/B-test state, not product data.
        const { trailers: _trailers, ...productPayload } = payload;
        return productPayload;
      }
    } catch { /* ignore malformed or unrelated initial state */ }
  }
  return null;
}

export function hashProductDetailPayload(payload: Record<string, unknown>): string {
  return createHash("sha256").update(canonicalJson(payload)).digest("hex");
}

function extractProductDetailMetadata(payload: Record<string, unknown>): {
  metadata: ProductDetailMetadata;
  sourceProductId: string | null;
  schemaError: string | null;
} {
  const metadata = emptyProductDetailMetadata();
  const imagesSection = object(payload.imagesSection);
  const sizesSection = object(payload.sizesSection);
  const product = object(imagesSection?.product) ?? object(sizesSection?.product);
  const sourceProductId = product?.id === undefined || product?.id === null ? null : String(product.id);
  let schemaError: string | null = null;
  const color = string(product?.colorLabel).trim();
  metadata.colorOriginal = color || null;

  const selectionType = object(object(payload.productSelectionSection)?.type);
  if (selectionType) {
    const selectionCase = string(selectionType.$case);
    if (selectionCase === "productSelection") {
      const selection = object(selectionType.productSelection);
      const items = Array.isArray(selection?.items) ? selection.items : [];
      for (const [position, colorItem] of items.entries()) {
        const option = object(colorItem);
        const label = string(option?.colorLabel).trim();
        const externalId = option?.id === undefined || option?.id === null ? null : String(option.id);
        if (!option || !label || !externalId) { schemaError ??= `invalid_color_option:${position}`; continue; }
        metadata.colorOptions.push({
          externalId,
          label,
          url: nullableHttpUrl(option.path),
          selected: externalId === sourceProductId
        });
      }
    } else if (selectionCase === "noSiblings") {
      const noSiblings = object(selectionType.noSiblings);
      const label = string(noSiblings?.colorLabel).trim() || color;
      if (!label || !sourceProductId) schemaError ??= "invalid_color_option:noSiblings";
      else metadata.colorOptions.push({
          externalId: sourceProductId,
          label,
          url: nullableHttpUrl(product?.path),
          selected: true
        });
    } else {
      schemaError ??= `unknown_product_selection:${selectionCase || "missing"}`;
    }
  } else if (color) {
    metadata.colorOptions.push({
      externalId: sourceProductId,
      label: color,
      url: nullableHttpUrl(product?.path),
      selected: true
    });
  }

  const images = Array.isArray(imagesSection?.images) ? imagesSection.images : [];
  mergeUnique(metadata.imageUrls, images.flatMap((item) => {
    const src = string(object(object(item)?.image)?.src).trim();
    return src && isHttpUrl(src) ? [src] : [];
  }));

  const sizeSelection = object(sizesSection?.sizeSelection);
  const sizeType = object(sizeSelection?.type);
  const sizeCase = string(sizeType?.$case);
  const sizes = extractDisplayedSizes(sizeType, sizeCase);
  mergeUnique(metadata.sizes, sizes.flatMap((item) => {
    const label = string(object(item)?.label).trim();
    return label ? [label] : [];
  }));

  if (sizeType) {
    if (!new Set(["sizes", "sizeRuns", "oneSize"]).has(sizeCase)) {
      schemaError ??= `unknown_size_type:${sizeCase || "missing"}`;
    }
    for (const [position, item] of sizes.entries()) {
      const option = object(item);
      const externalId = option?.sizeId === undefined || option?.sizeId === null ? "" : String(option.sizeId);
      const label = string(option?.label).trim();
      const availability = object(option?.availability);
      const availabilityCase = string(availability?.$case).trim();
      if (!option || !externalId || !label || !availabilityCase) {
        schemaError ??= `invalid_size_option:${position}`;
        continue;
      }
      if (!new Set(["inStock", "soldOut"]).has(availabilityCase)) {
        schemaError ??= `unknown_size_availability:${availabilityCase}`;
      }
      const productSize = (Array.isArray(product?.sizes) ? product.sizes : [])
        .map(object).find((candidate) => String(candidate?.id ?? "") === externalId) ?? null;
      const groupResult = extractSizeGroup(productSize);
      if (groupResult.schemaError) schemaError ??= groupResult.schemaError;
      metadata.sizeOptions.push({
        externalId,
        label,
        group: groupResult.group,
        selected: option.selected === true || option.isSelected === true,
        selectable: availabilityCase === "inStock",
        availability: availabilityCase
      });
    }
  }

  const productSizes = Array.isArray(product?.sizes) ? product.sizes : [];
  mergeUnique(metadata.otherSizes, productSizes.flatMap((item) => {
    const group = extractSizeGroup(object(item)).group;
    return group ? [group] : [];
  }));

  const linksSection = object(payload.linksSection);
  const breadcrumbs = Array.isArray(linksSection?.breadcrumbs) ? linksSection.breadcrumbs : [];
  mergeUnique(metadata.categories, breadcrumbs.flatMap((item) => {
    const breadcrumb = object(item);
    const label = string(breadcrumb?.label).trim();
    const path = string(object(breadcrumb?.url)?.url);
    return label && path.startsWith("/c/") && !path.includes("?") ? [label] : [];
  }));

  const articleDetails = object(object(payload.productDetailsSection)?.articleDetails);
  const lanes = Array.isArray(articleDetails?.lanes) ? articleDetails.lanes : [];
  for (const [position, item] of lanes.entries()) {
    const lane = object(item);
    const type = object(lane?.type);
    const laneType = string(type?.$case);
    const sourceLabel = string(lane?.label).trim();
    if (!lane || !type || !laneType || !sourceLabel) {
      schemaError ??= `invalid_detail_lane:${position}`;
      continue;
    }
    if (laneType === "materialLane") {
      const materialLane = object(type?.materialLane);
      const values = stringArray(materialLane?.bulletPoints);
      mergeUnique(metadata.materials, values.map(stripAttributeLabel));
      appendDetailSection(metadata.sections, "material_composition", sourceLabel, laneType, position, values);
    } else if (laneType === "sizeLane") {
      const values = stringArray(object(type?.sizeLane)?.bulletPoints);
      const measurements = values.filter(isMeasurementValue);
      const fitValues = values.filter((value) => !isMeasurementValue(value));
      mergeUnique(metadata.styles, fitValues);
      appendDetailSection(metadata.sections, "size_and_fit", sourceLabel, laneType, position, fitValues);
      appendDetailSection(metadata.sections, "measurements", sourceLabel, laneType, position, measurements);
    } else if (laneType === "bulletPointLane") {
      const values = stringArray(object(type?.bulletPointLane)?.bulletPoints);
      mergeUnique(metadata.features, values);
      appendDetailSection(metadata.sections, "design_and_extras", sourceLabel, laneType, position, values);
    } else if (laneType === "regularLane") {
      const values = stringArray(object(type?.regularLane)?.items);
      mergeUnique(metadata.features, values);
      appendDetailSection(metadata.sections, "design_and_extras", sourceLabel, laneType, position, values);
    } else if (laneType === "sustainabilityInfoLane") {
      const cluster = object(object(type.sustainabilityInfoLane)?.cluster);
      const attributes = Array.isArray(cluster?.attributes) ? cluster.attributes : [];
      const values = attributes.flatMap((item) => {
        const attribute = object(item);
        const label = string(attribute?.label).trim().replace(/:\s*$/, "");
        const text = string(attribute?.text).trim();
        return text ? [`${label ? `${label}: ` : ""}${text}`] : [];
      });
      appendDetailSection(metadata.sections, "design_and_extras", sourceLabel, laneType, position, values);
    } else if (laneType !== "manufacturerLane") {
      schemaError ??= `unknown_detail_lane:${laneType}`;
    }
  }
  addAbsentDetailSections(metadata.sections);
  const productName = string(product?.name).trim();
  if (productName) metadata.productTypes.push(productName);
  metadata.isPremium = extractIsPremium(payload);
  return { metadata, sourceProductId, schemaError };
}

function extractFallbackMetadataFromHtml(html: string): ProductDetailMetadata {
  let colorOriginal: string | null = null;
  let categories: string[] = [];
  const attributes = {
    sizes: [] as string[], otherSizes: [] as string[], materials: [] as string[],
    patterns: [] as string[], features: [] as string[], styles: [] as string[], productTypes: [] as string[]
  };
  let isPremium = false;
  const scriptPattern = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  for (const match of html.matchAll(scriptPattern)) {
    if (!/\btype\s*=\s*["']application\/ld\+json["']/i.test(match[1] ?? "")) continue;
    try {
      const value = JSON.parse(match[2] ?? "");
      colorOriginal ??= findStructuredColor(value);
      if (!categories.length) categories = findBreadcrumbCategories(value);
      if (!categories.length) categories = findStructuredProductCategory(value);
      mergeUnique(attributes.sizes, findStrings(value, ["size", "sizes", "availableSizes", "sizeLabels"]));
      mergeUnique(attributes.otherSizes, findStrings(value, ["otherSizes", "specialSizes", "sizeGroups"]));
      mergeUnique(attributes.materials, findStrings(value, ["material", "materials", "materialName", "materialComposition"]));
      mergeUnique(attributes.patterns, findStrings(value, ["pattern", "patterns", "patternName"]));
      mergeUnique(attributes.features, findStrings(value, ["features", "productFeatures", "additionalProperty"]));
      mergeUnique(attributes.styles, findStrings(value, ["style", "styles", "styleName"]));
      mergeUnique(attributes.productTypes, findStrings(value, ["productType", "productTypes", "productTypeName"]));
      isPremium ||= findStrings(value, ["badge", "badges", "label", "name"]).some((item) => isPremiumText(item));
    } catch { /* ignore unrelated or malformed structured data */ }
  }

  const selected = colorOriginal ? null : html.match(/data-testid=["']productColorInfoSelectedOptionName["'][^>]*>([\s\S]*?)<\/span>/i)?.[1];
  if (!colorOriginal && selected) {
    const color = decodeHtml(selected.replace(/<[^>]+>/g, " ")).trim();
    if (color) colorOriginal = color;
  }

  const colorLabel = colorOriginal ? null : html.match(/"colorLabel"\s*:\s*"((?:\\.|[^"\\])*)"/i)?.[1];
  if (!colorOriginal && colorLabel) {
    try { colorOriginal = JSON.parse(`"${colorLabel}"`); }
    catch { /* ignore malformed JSON string */ }
  }
  return {
    colorOriginal, categories, imageUrls: [], ...attributes,
    isPremium,
    sections: [], colorOptions: [], sizeOptions: []
  };
}

function emptyProductDetailMetadata(): ProductDetailMetadata {
  return {
    colorOriginal: null, categories: [], imageUrls: [], sizes: [], otherSizes: [], materials: [],
    patterns: [], features: [], styles: [], productTypes: [], isPremium: false, sections: [], colorOptions: [], sizeOptions: []
  };
}

function extractIsPremium(payload: Record<string, unknown>): boolean {
  const imagesSection = object(payload.imagesSection);
  const badges = Array.isArray(imagesSection?.badges) ? imagesSection.badges : [];
  if (badges.some((item) => {
    const badge = object(item);
    const tracker = object(badge?.tracker);
    const type = object(badge?.type);
    const productAttribute = object(type?.productAttribute);
    return isPremiumText(string(tracker?.contextKey)) || isPremiumText(string(productAttribute?.label));
  })) return true;

  const infoBox = object(object(payload.hotProductSection)?.infoBox);
  return isPremiumPrefix(string(infoBox?.subline));
}

function isPremiumText(value: string): boolean {
  return value.trim().toLocaleLowerCase("lt") === "premium" ||
    value.trim().toLocaleLowerCase("lt") === "product.badges.premium";
}

function isPremiumPrefix(value: string): boolean {
  return value.trim().toLocaleLowerCase("lt").startsWith("premium ");
}

const DETAIL_SECTION_LABELS: Record<ProductDetailSectionKey, string> = {
  size_and_fit: "Dydis ir forma",
  measurements: "Išmatavimai",
  material_composition: "Medžiagų sudėtis",
  design_and_extras: "Dizainas ir priedai"
};

function appendDetailSection(
  sections: ProductDetailSection[],
  key: ProductDetailSectionKey,
  sourceLabel: string,
  sourceType: string,
  position: number,
  values: string[]
): void {
  if (!values.length) return;
  const existing = sections.find((section) => section.key === key && section.status === "present");
  if (existing) {
    existing.items.push(...values.map(parseDetailItem));
    return;
  }
  sections.push({ key, sourceLabel, status: "present", sourceType, position, items: values.map(parseDetailItem) });
}

function addAbsentDetailSections(sections: ProductDetailSection[]): void {
  for (const [position, key] of productDetailSectionKeys.entries()) {
    if (sections.some((section) => section.key === key)) continue;
    sections.push({
      key, sourceLabel: DETAIL_SECTION_LABELS[key], status: "source_absent",
      sourceType: null, position: 10_000 + position, items: []
    });
  }
  sections.sort((left, right) => left.position - right.position);
}

function parseDetailItem(rawText: string): ProductDetailItem {
  const separator = rawText.indexOf(":");
  const label = separator >= 0 ? rawText.slice(0, separator).trim() || null : null;
  const value = (separator >= 0 ? rawText.slice(separator + 1) : rawText).trim();
  const unit = value.match(/\d+(?:[.,]\d+)?\s*(mm|cm|m|kg|g|%)(?=\s|\b|\(|,|$)/i)?.[1] ?? null;
  return { label, value, unit, rawText };
}

function isMeasurementValue(value: string): boolean {
  return /\d+(?:[.,]\d+)?\s*(?:mm|cm|m)\b/i.test(value) || /\(dydis\s+[^)]+\)/i.test(value);
}

function extractSizeGroup(productSize: Record<string, unknown> | null): { group: string | null; schemaError: string | null } {
  if (!productSize) return { group: null, schemaError: null };
  const size = object(object(productSize.shopSize)?.size);
  if (!size) return { group: null, schemaError: null };
  const sizeCase = string(size.$case);
  if (sizeCase === "twoDimension") {
    return { group: string(object(size.twoDimension)?.secondDimension).trim() || null, schemaError: null };
  }
  if (sizeCase === "pants") {
    return { group: string(object(size.pants)?.length).trim() || null, schemaError: null };
  }
  if (sizeCase === "singleDimension" || sizeCase === "oneDimension") return { group: null, schemaError: null };
  return { group: null, schemaError: `unknown_size_dimension:${sizeCase || "missing"}` };
}

function extractDisplayedSizes(sizeType: Record<string, unknown> | null, sizeCase: string): unknown[] {
  if (!sizeType) return [];
  if (sizeCase === "sizes") {
    const list = object(sizeType.sizes);
    return Array.isArray(list?.sizes) ? list.sizes : [];
  }
  if (sizeCase === "sizeRuns") {
    const runs = Array.isArray(object(sizeType.sizeRuns)?.sizeRuns)
      ? object(sizeType.sizeRuns)?.sizeRuns as unknown[]
      : [];
    const selected = runs.map(object).find((run) =>
      string(object(object(run?.sizeSource)?.type)?.$case) === "shop"
    ) ?? object(runs[0]);
    return Array.isArray(selected?.sizes) ? selected.sizes : [];
  }
  if (sizeCase === "oneSize") {
    const size = object(object(sizeType.oneSize)?.size);
    return size ? [size] : [];
  }
  return [];
}

function nullableHttpUrl(value: unknown): string | null {
  const candidate = string(value).trim();
  if (!candidate) return null;
  try {
    const url = new URL(candidate, "https://www.aboutyou.lt");
    return ["http:", "https:"].includes(url.protocol) ? url.toString() : null;
  } catch { return null; }
}

function decodeInitialStateKey(value: string): string {
  if (!value.startsWith('"')) return value;
  try {
    const decoded = JSON.parse(value);
    return typeof decoded === "string" ? decoded : value;
  } catch { return value; }
}

function preferValues(primary: string[], fallback: string[]): string[] {
  return primary.length ? primary : fallback;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.flatMap((item) => typeof item === "string" && item.trim() ? [item.trim()] : [])
    : [];
}

function stripAttributeLabel(value: string): string {
  const separator = value.indexOf(":");
  return separator >= 0 ? value.slice(separator + 1).trim() : value;
}

function isHttpUrl(value: string): boolean {
  try { return ["http:", "https:"].includes(new URL(value).protocol); }
  catch { return false; }
}

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, child]) => `${JSON.stringify(key)}:${canonicalJson(child)}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

export async function enrichMissingProductMetadata(
  page: Page,
  products: Product[],
  options: {
    limit?: number;
    concurrency?: number;
    delayMs?: number;
    timeoutMs?: number;
    onlyMissing?: boolean;
    failOnRateLimit?: boolean;
    onProgress?: (progress: ProductMetadataEnrichmentProgress) => void;
  } = {}
): Promise<ProductMetadataEnrichmentResult> {
  const limit = Math.max(0, Math.min(options.limit ?? 100, products.length));
  const missingIndexes = products.flatMap((product, index) =>
    options.onlyMissing !== false && product.colorOriginal && product.categories.length ? [] : [index]
  ).slice(0, limit);
  if (!missingIndexes.length) return {
    products, attempted: 0, refreshed: 0, refreshedExternalIds: [], foundColors: 0, foundCategories: 0,
    attempts: [], rateLimited: false
  };

  const enriched = [...products];
  const concurrency = Math.max(1, Math.min(options.concurrency ?? 1, 12, missingIndexes.length));
  const delayMs = Math.max(0, options.delayMs ?? 750);
  let cursor = 0;
  let processed = 0;
  let foundColors = 0;
  let foundCategories = 0;
  const refreshedExternalIds: string[] = [];
  const attempts: ProductMetadataAttempt[] = [];
  let rateLimited = false;
  let nextRequestAt = Date.now();
  const report = () => options.onProgress?.({ processed, total: missingIndexes.length, foundColors, foundCategories });
  const waitForRequestSlot = async () => {
    const now = Date.now();
    const scheduledAt = Math.max(now, nextRequestAt);
    nextRequestAt = scheduledAt + delayMs;
    if (scheduledAt > now) await new Promise((resolve) => setTimeout(resolve, scheduledAt - now));
  };

  const worker = async () => {
    while (cursor < missingIndexes.length && !rateLimited) {
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
        if (response.status() === 429 || response.status() === 403) {
          attempts.push(metadataAttempt(product.externalId, null, null, false, `http_${response.status()}`, response));
          if (options.failOnRateLimit) rateLimited = true;
          processed += 1;
          continue;
        }
        if (!response.ok()) {
          attempts.push(metadataAttempt(product.externalId, null, null, false, `http_${response.status()}`, response));
          processed += 1;
          continue;
        }
        if (response.ok()) {
          const html = await response.text();
          const extraction = extractProductDetailFromHtml(html);
          const metadata = extraction.metadata;
          const metadataFound = hasProductDetailMetadata(metadata);
          const error = !extraction.rawPayload
            ? "product_detail_payload_missing"
            : metadataFound ? null : "product_detail_metadata_missing";
          attempts.push(metadataAttempt(
            product.externalId, extraction.rawPayload, extraction.payloadHash, metadataFound,
            error, response,
            extraction.rawPayload ? null : html
          ));
          if (metadataFound) {
            enriched[productIndex] = {
              ...product,
              imageUrls: metadata.imageUrls.length ? metadata.imageUrls : product.imageUrls,
              categories: metadata.categories.length ? metadata.categories : product.categories,
              sizes: metadata.sizes.length ? metadata.sizes : product.sizes,
              otherSizes: metadata.otherSizes.length ? metadata.otherSizes : product.otherSizes,
              materials: metadata.materials.length ? metadata.materials : product.materials,
              patterns: metadata.patterns.length ? metadata.patterns : product.patterns,
              features: metadata.features.length ? metadata.features : product.features,
              styles: metadata.styles.length ? metadata.styles : product.styles,
              productTypes: metadata.productTypes.length ? metadata.productTypes : product.productTypes,
              ...(metadata.colorOriginal ? {
                colorOriginal: metadata.colorOriginal,
                colorFamily: normalizeColor(metadata.colorOriginal),
                colorShade: normalizeColorShade(metadata.colorOriginal)
              } : {})
            };
            refreshedExternalIds.push(product.externalId);
            if (metadata.colorOriginal && !product.colorOriginal) foundColors += 1;
            if (metadata.categories.length && !product.categories.length) foundCategories += 1;
          }
        }
      } catch (error) {
        attempts.push(metadataAttempt(product.externalId, null, null, false, "request_failed"));
      }
      processed += 1;
      if (processed === missingIndexes.length || processed % 25 === 0) report();
    }
  };

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  return {
    products: enriched, attempted: attempts.length, refreshed: refreshedExternalIds.length,
    refreshedExternalIds, foundColors, foundCategories, attempts, rateLimited
  };
}

function metadataAttempt(
  externalId: string,
  rawPayload: Record<string, unknown> | null,
  payloadHash: string | null,
  metadataFound: boolean,
  error: string | null,
  response?: APIResponse | Response,
  responseHtml: string | null = null
): ProductMetadataAttempt {
  return {
    externalId, rawPayload, payloadHash, metadataFound, error,
    sourceEndpoint: PRODUCT_DETAIL_ENDPOINT,
    parserVersion: PRODUCT_DETAIL_PARSER_VERSION,
    httpStatus: response?.status() ?? null,
    contentType: response?.headers()["content-type"] ?? null,
    responseSize: responseHtml === null
      ? parseContentLength(response?.headers()["content-length"])
      : Buffer.byteLength(responseHtml),
    finalUrl: response?.url() ?? null,
    responseHtml
  };
}

function parseContentLength(value: string | undefined): number | null {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : null;
}

function hasProductDetailMetadata(metadata: ProductDetailMetadata): boolean {
  return Boolean(metadata.colorOriginal || metadata.categories.length || metadata.imageUrls.length || metadata.sizes.length ||
    metadata.otherSizes.length || metadata.materials.length || metadata.patterns.length || metadata.features.length ||
    metadata.styles.length || metadata.productTypes.length || metadata.isPremium);
}

function mergeUnique(target: string[], values: string[]): void {
  const known = new Set(target);
  for (const value of values) if (!known.has(value)) { known.add(value); target.push(value); }
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

function findBreadcrumbCategories(value: unknown): string[] {
  if (!value || typeof value !== "object") return [];
  const objectValue = value as Record<string, unknown>;
  const type = objectValue["@type"];
  if (type === "BreadcrumbList" || (Array.isArray(type) && type.includes("BreadcrumbList"))) {
    const elements = Array.isArray(objectValue.itemListElement) ? objectValue.itemListElement : [];
    return elements
      .flatMap((element): Array<{ position: number; name: string }> => {
        if (!element || typeof element !== "object") return [];
        const listItem = element as Record<string, unknown>;
        const item = listItem.item;
        if (!item || typeof item !== "object") return [];
        const category = item as Record<string, unknown>;
        const name = typeof category.name === "string" ? category.name.trim() : "";
        const id = typeof category["@id"] === "string" ? category["@id"] : "";
        if (!name || !isPrimaryCategoryUrl(id) || /^(moterims|vaikams)$/i.test(name)) return [];
        return [{ position: typeof listItem.position === "number" ? listItem.position : Number.MAX_SAFE_INTEGER, name }];
      })
      .sort((left, right) => left.position - right.position)
      .map((item) => item.name);
  }
  for (const child of Array.isArray(value) ? value : Object.values(objectValue)) {
    const categories = findBreadcrumbCategories(child);
    if (categories.length) return categories;
  }
  return [];
}

function findStructuredProductCategory(value: unknown): string[] {
  if (!value || typeof value !== "object") return [];
  const objectValue = value as Record<string, unknown>;
  const type = objectValue["@type"];
  const isProduct = type === "Product" || type === "ProductGroup" ||
    (Array.isArray(type) && (type.includes("Product") || type.includes("ProductGroup")));
  if (isProduct) {
    const category = objectValue.category;
    if (typeof category === "string" && category.trim()) return [category.trim()];
    if (category && typeof category === "object") {
      const name = (category as Record<string, unknown>).name;
      if (typeof name === "string" && name.trim()) return [name.trim()];
    }
  }
  for (const child of Array.isArray(value) ? value : Object.values(objectValue)) {
    const categories = findStructuredProductCategory(child);
    if (categories.length) return categories;
  }
  return [];
}

function isPrimaryCategoryUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return (url.hostname === "aboutyou.lt" || url.hostname.endsWith(".aboutyou.lt")) &&
      url.pathname.startsWith("/c/") && !url.search;
  } catch {
    return false;
  }
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
    complete: raw.size > 0 && (raw.size >= targetTotal || (initial.total === null && stable >= 6))
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
    categories?: string[];
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
      categories: item.categories ?? [],
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
    categories: findStrings(tile, ["category", "categoryName", "categoryNames", "categories"]),
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
