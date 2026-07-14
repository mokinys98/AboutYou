import type { SupabaseClient } from "@supabase/supabase-js";
import type { Alert, CatalogAlertFilters } from "@catalog/shared";

export type TelegramEnv = {
  TELEGRAM_BOT_TOKEN?: string;
  TELEGRAM_BOT_USERNAME?: string;
  TELEGRAM_WEBHOOK_SECRET?: string;
  WEB_APP_URL?: string;
};

type TelegramProduct = {
  id: string;
  name: string;
  brand: string;
  currentPrice: number;
  previousPrice?: number | null;
  currency: string;
  imageUrls: string[];
};

export type TelegramNotification = {
  kind: "filter" | "product";
  alertId: string;
  name: string;
  filters?: CatalogAlertFilters;
  triggers: string[];
  totalCount: number;
  products: TelegramProduct[];
};

type ClaimedNotification = {
  id: string;
  alert_id: string;
  user_id: string;
  payload: TelegramNotification;
  chat_id: number | string;
  lease_token: string;
  attempts: number;
};

class TelegramApiError extends Error {
  constructor(message: string, readonly status: number, readonly retryAfter?: number) { super(message); }
}

export function canonicalAlertFilters(filters: CatalogAlertFilters): CatalogAlertFilters {
  const normalize = (values: string[]) => [...new Set(values.map((value) => value.trim()).filter(Boolean))].sort((a, b) => a.localeCompare(b, "lt"));
  return {
    ...filters,
    brands: normalize(filters.brands),
    brandTiers: [...new Set(filters.brandTiers)].sort(),
    sources: normalize(filters.sources),
    categories: normalize(filters.categories),
    colors: [...new Set(filters.colors)].sort(),
    colorShades: [...new Set(filters.colorShades)].sort(),
    sizes: normalize(filters.sizes),
    otherSizes: normalize(filters.otherSizes),
    materials: normalize(filters.materials),
    patterns: normalize(filters.patterns),
    features: normalize(filters.features),
    styles: normalize(filters.styles),
    productTypes: normalize(filters.productTypes)
  };
}

export function hasMeaningfulAlertFilters(filters: CatalogAlertFilters): boolean {
  return Boolean(filters.categoryPath || filters.isPremium || filters.excludeBasics || filters.priceMin !== undefined ||
    filters.priceMax !== undefined || filters.discountMin !== undefined || filters.belowObserved30d ||
    filters.brands.length || filters.brandTiers.length || filters.sources.length || filters.categories.length ||
    filters.colors.length || filters.colorShades.length || filters.sizes.length || filters.otherSizes.length ||
    filters.materials.length || filters.patterns.length || filters.features.length || filters.styles.length || filters.productTypes.length);
}

export async function alertFilterFingerprint(filters: CatalogAlertFilters): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(canonicalAlertFilters(filters)));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function mapAlertRow(row: Record<string, any>): Alert {
  const base = {
    id: row.id,
    kind: row.kind,
    name: row.name,
    enabled: row.enabled,
    filters: row.filters,
    conditions: row.conditions,
    lastEvaluatedAt: row.last_evaluated_at,
    lastTriggeredAt: row.last_triggered_at,
    lastDeliveryError: row.last_delivery_error,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
  if (row.kind === "filter") return { ...base, product: null } as Alert;
  const product = Array.isArray(row.products) ? row.products[0] : row.products;
  return {
    ...base,
    filters: null,
    product: {
      id: row.product_id,
      name: product?.name ?? "Produktas",
      brand: product?.brand ?? "",
      imageUrl: Array.isArray(product?.image_urls) ? product.image_urls[0] ?? null : null
    }
  } as Alert;
}

export function notificationUrl(payload: TelegramNotification, webAppUrl: string): string {
  const base = webAppUrl.replace(/\/$/, "");
  if (payload.kind === "product") return `${base}/products/${encodeURIComponent(payload.products[0]?.id ?? "")}`;
  const query = new URLSearchParams();
  const filters = payload.filters ?? {} as CatalogAlertFilters;
  const lists: Array<[keyof CatalogAlertFilters, string]> = [
    ["brands", "brands"], ["brandTiers", "brand_tiers"], ["sources", "sources"], ["categories", "categories"],
    ["colors", "colors"], ["colorShades", "color_shades"], ["sizes", "sizes"], ["otherSizes", "other_sizes"],
    ["materials", "materials"], ["patterns", "patterns"], ["features", "features"], ["styles", "styles"], ["productTypes", "product_types"]
  ];
  for (const [property, key] of lists) {
    const value = filters[property];
    if (Array.isArray(value) && value.length) query.set(key, value.join(","));
  }
  if (filters.categoryPath) query.set("category", filters.categoryPath);
  if (filters.isPremium) query.set("premium", "true");
  if (filters.excludeBasics) query.set("exclude_basics", "true");
  if (filters.priceMin !== undefined) query.set("price_min", String(filters.priceMin / 100));
  if (filters.priceMax !== undefined) query.set("price_max", String(filters.priceMax / 100));
  if (filters.discountMin !== undefined) query.set("discount_min", String(filters.discountMin));
  if (filters.belowObserved30d) query.set("below_observed_30d", "true");
  if (filters.priceComparison && filters.priceComparison !== "observed") query.set("price_comparison", filters.priceComparison);
  return `${base}/?${query.toString()}`;
}

export function selectNotificationImages(payload: TelegramNotification): string[] {
  if (payload.kind === "filter" && payload.products.length > 1) {
    return payload.products.flatMap((product) => product.imageUrls[0] ? [product.imageUrls[0]] : []).slice(0, 6);
  }
  return (payload.products[0]?.imageUrls ?? []).slice(0, 10);
}

function escapeHtml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

const triggerLabels: Record<string, string> = {
  newMatches: "Naujos filtro prekės",
  priceBelow: "Pasiekta pasirinkta kaina",
  belowObserved30d: "Naujas 30 d. kainos minimumas",
  belowSourceLpl30d: "Kaina pasiekė arba nukrito žemiau LPL",
  backInCatalog: "Prekė vėl kataloge"
};

export function notificationText(payload: TelegramNotification): string {
  const triggerText = payload.triggers.map((trigger) => trigger.startsWith("size:") ? `Atsirado dydis ${trigger.slice(5)}` : triggerLabels[trigger] ?? trigger).join(" · ");
  const product = payload.products[0];
  const price = product ? `${(product.currentPrice / 100).toFixed(2)} ${escapeHtml(product.currency)}` : "";
  const change = product?.previousPrice && product.previousPrice !== product.currentPrice
    ? ` (buvo ${(product.previousPrice / 100).toFixed(2)} ${escapeHtml(product.currency)})` : "";
  return `<b>${escapeHtml(payload.name)}</b>\n${escapeHtml(triggerText)}\n` +
    (payload.kind === "filter" ? `Rasta naujų prekių: <b>${payload.totalCount}</b>` : `${escapeHtml(product?.brand ?? "")} ${escapeHtml(product?.name ?? "")}\n<b>${price}</b>${change}`);
}

async function telegramRequest(env: TelegramEnv, method: string, body: unknown, fetcher: typeof fetch): Promise<any> {
  if (!env.TELEGRAM_BOT_TOKEN) throw new TelegramApiError("Telegram botas nesukonfigūruotas", 503);
  const response = await fetcher(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body)
  });
  const result = await response.json().catch(() => null) as any;
  if (!response.ok || !result?.ok) {
    throw new TelegramApiError(result?.description ?? `Telegram API klaida (${response.status})`, result?.error_code ?? response.status,
      result?.parameters?.retry_after);
  }
  return result.result;
}

function keyboard(url: string) {
  return { inline_keyboard: [[{ text: "Atidaryti kataloge", url }]] };
}

export async function sendTelegramNotification(
  chatId: string | number,
  payload: TelegramNotification,
  env: TelegramEnv,
  fetcher: typeof fetch = fetch
): Promise<number[]> {
  if (!env.WEB_APP_URL) throw new TelegramApiError("Nesukonfigūruotas WEB_APP_URL", 503);
  const url = notificationUrl(payload, env.WEB_APP_URL);
  const images = selectNotificationImages(payload);
  const text = notificationText(payload);
  const mediaHtml = images.length === 1
    ? `<figure><img src="${escapeHtml(images[0]!)}"/></figure>`
    : images.length > 1 ? `<tg-collage>${images.map((image) => `<img src="${escapeHtml(image)}"/>`).join("")}</tg-collage>` : "";
  try {
    const message = await telegramRequest(env, "sendRichMessage", {
      chat_id: chatId,
      rich_message: { html: `<h2>${escapeHtml(payload.name)}</h2>${mediaHtml}<p>${text.replace(/\n/g, "<br>")}</p>` },
      reply_markup: keyboard(url)
    }, fetcher);
    return message?.message_id ? [message.message_id] : [];
  } catch (error) {
    if (error instanceof TelegramApiError && (error.status === 401 || error.status === 403 || error.status === 429 || error.status >= 500)) throw error;
  }

  if (images.length >= 2) {
    const album = await telegramRequest(env, "sendMediaGroup", {
      chat_id: chatId,
      media: images.map((image, index) => ({ type: "photo", media: image, ...(index === 0 ? { caption: text, parse_mode: "HTML" } : {}) }))
    }, fetcher) as Array<{ message_id: number }>;
    const link = await telegramRequest(env, "sendMessage", { chat_id: chatId, text: "Atidaryti rezultatą", reply_markup: keyboard(url) }, fetcher);
    return [...album.map((message) => message.message_id), link.message_id].filter(Boolean);
  }
  if (images.length === 1) {
    const message = await telegramRequest(env, "sendPhoto", {
      chat_id: chatId, photo: images[0], caption: text, parse_mode: "HTML", reply_markup: keyboard(url)
    }, fetcher);
    return message?.message_id ? [message.message_id] : [];
  }
  const message = await telegramRequest(env, "sendMessage", { chat_id: chatId, text, parse_mode: "HTML", reply_markup: keyboard(url) }, fetcher);
  return message?.message_id ? [message.message_id] : [];
}

export async function sendTelegramText(chatId: string | number, text: string, env: TelegramEnv, fetcher: typeof fetch = fetch): Promise<number | null> {
  const message = await telegramRequest(env, "sendMessage", { chat_id: chatId, text, parse_mode: "HTML" }, fetcher);
  return message?.message_id ?? null;
}

export async function processTelegramAlerts(db: SupabaseClient, env: TelegramEnv, fetcher: typeof fetch = fetch): Promise<{ evaluated: number; sent: number }> {
  const { data: evaluated, error: evaluationError } = await db.rpc("evaluate_telegram_alerts", { p_limit: 500 });
  if (evaluationError) throw new Error(`Alertų įvertinti nepavyko: ${evaluationError.message}`);
  const { data, error } = await db.rpc("claim_telegram_notifications", { p_limit: 20, p_lease_minutes: 5 });
  if (error) throw new Error(`Pranešimų rezervuoti nepavyko: ${error.message}`);
  let sent = 0;
  for (const item of (data ?? []) as ClaimedNotification[]) {
    try {
      const messageIds = await sendTelegramNotification(item.chat_id, item.payload, env, fetcher);
      const { error: completeError } = await db.rpc("complete_telegram_notification", {
        p_id: item.id, p_lease_token: item.lease_token, p_message_ids: messageIds
      });
      if (completeError) throw new Error(completeError.message);
      sent += 1;
    } catch (error) {
      const telegramError = error instanceof TelegramApiError ? error : null;
      const { error: failError } = await db.rpc("fail_telegram_notification", {
        p_id: item.id,
        p_lease_token: item.lease_token,
        p_error: error instanceof Error ? error.message : String(error),
        p_retry_after_seconds: telegramError?.retryAfter ?? null,
        p_permanent: telegramError?.status === 401 || telegramError?.status === 403
      });
      if (failError) console.error(JSON.stringify({ event: "telegram_notification_fail_update_failed", id: item.id, error: failError.message }));
    }
  }
  return { evaluated: Number(evaluated ?? 0), sent };
}
