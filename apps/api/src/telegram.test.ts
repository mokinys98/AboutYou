import { describe, expect, it, vi } from "vitest";
import { alertFilterFingerprint, canonicalAlertFilters, hasMeaningfulAlertFilters, notificationText, notificationUrl, selectNotificationImages, sendTelegramNotification, type TelegramNotification } from "./telegram";

const filters = {
  brands: [], brandTiers: [], sources: [], categories: [], colors: [], colorShades: [], sizes: [], otherSizes: [],
  materials: [], patterns: [], features: [], styles: [], productTypes: [], isPremium: false, excludeBasics: false,
  excludeAccessories: false,
  belowObserved30d: false, priceComparison: "observed" as const
};
const product = (id: string, images: string[]) => ({
  id, name: `Produktas ${id}`, brand: "Brand", currentPrice: 3999, previousPrice: 4999, currency: "EUR", imageUrls: images
});

describe("Telegram alerts", () => {
  it("canonicalizes filter arrays and creates stable fingerprints", async () => {
    const first = canonicalAlertFilters({ ...filters, brands: [" Nike ", "Adidas", "Nike"] });
    const second = canonicalAlertFilters({ ...filters, brands: ["Adidas", "Nike"] });
    expect(first.brands).toEqual(["Adidas", "Nike"]);
    expect(await alertFilterFingerprint(first)).toBe(await alertFilterFingerprint(second));
    expect(hasMeaningfulAlertFilters(filters)).toBe(false);
    expect(hasMeaningfulAlertFilters({ ...filters, isPremium: true })).toBe(true);
    expect(hasMeaningfulAlertFilters({ ...filters, excludeAccessories: true })).toBe(true);
  });

  it("selects one image per product for filter batches and up to ten for one product", () => {
    const many: TelegramNotification = {
      kind: "filter", alertId: "a", name: "Nauji", filters, triggers: ["newMatches"], totalCount: 8,
      products: Array.from({ length: 8 }, (_, index) => product(String(index), [`https://img/${index}-1`, `https://img/${index}-2`]))
    };
    expect(selectNotificationImages(many)).toEqual(Array.from({ length: 6 }, (_, index) => `https://img/${index}-1`));
    expect(selectNotificationImages({ ...many, products: [product("one", Array.from({ length: 12 }, (_, i) => `https://img/${i}`))] })).toHaveLength(10);
  });

  it("builds internal product and filter links and escapes notification text", () => {
    const filterPayload: TelegramNotification = {
      kind: "filter", alertId: "a", name: "A&B <nauji>", filters: { ...filters, brands: ["Nike"], priceMax: 5000, excludeAccessories: true },
      triggers: ["newMatches"], totalCount: 2, products: [product("1", [])]
    };
    expect(notificationUrl(filterPayload, "https://catalog.example/")).toContain("brands=Nike");
    expect(notificationUrl(filterPayload, "https://catalog.example/")).toContain("price_max=50");
    expect(notificationUrl(filterPayload, "https://catalog.example/")).toContain("exclude_accessories=true");
    expect(notificationText(filterPayload)).toContain("A&amp;B &lt;nauji&gt;");
    expect(notificationUrl({ ...filterPayload, kind: "product" }, "https://catalog.example")).toBe("https://catalog.example/products/1");
  });

  it("uses a rich card and falls back to album plus link when rich messages are unsupported", async () => {
    const payload: TelegramNotification = {
      kind: "filter", alertId: "a", name: "Nauji", filters, triggers: ["newMatches"], totalCount: 2,
      products: [product("1", ["https://img/1"]), product("2", ["https://img/2"])]
    };
    const calls: string[] = [];
    const fetcher: typeof fetch = vi.fn(async (input) => {
      const method = String(input).split("/").at(-1)!; calls.push(method);
      if (method === "sendRichMessage") return new Response(JSON.stringify({ ok: false, error_code: 400, description: "method not found" }), { status: 400 });
      if (method === "sendMediaGroup") return new Response(JSON.stringify({ ok: true, result: [{ message_id: 1 }, { message_id: 2 }] }));
      return new Response(JSON.stringify({ ok: true, result: { message_id: 3 } }));
    }) as typeof fetch;
    await expect(sendTelegramNotification(123, payload, { TELEGRAM_BOT_TOKEN: "test", WEB_APP_URL: "https://catalog.example" }, fetcher)).resolves.toEqual([1, 2, 3]);
    expect(calls).toEqual(["sendRichMessage", "sendMediaGroup", "sendMessage"]);
  });
});
