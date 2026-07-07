import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { chromium, type APIRequestContext, type Browser } from "playwright";
import { extractProductDetailFromHtml } from "./index";

const productCases = [
  ["28410256", "https://www.aboutyou.lt/p/calvin-klein-underwear/boxer-trumpikes-28410256"],
  ["30763734", "https://www.aboutyou.lt/p/calvin-klein-underwear/boxer-trumpikes-30763734"],
  ["31866800", "https://www.aboutyou.lt/p/calvin-klein-underwear/boxer-trumpikes-31866800"]
] as const;

describe("live ABOUT YOU metadata sync product pages", () => {
  let browser: Browser;
  let request: APIRequestContext;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
    request = context.request;
  });

  afterAll(async () => {
    await browser.close();
  });

  it.each(productCases)("parses product %s with images", async (externalId, url) => {
    const response = await request.get(url, {
      failOnStatusCode: false,
      headers: { accept: "text/html,application/xhtml+xml" },
      timeout: 20_000
    });

    expect(response.status()).toBe(200);
    const finalUrl = new URL(response.url());
    expect(finalUrl.pathname).toMatch(new RegExp(`-${externalId}/?$`));

    const extraction = extractProductDetailFromHtml(await response.text());
    expect(extraction.sourceProductId).toBe(externalId);
    expect(extraction.rawPayload).not.toBeNull();
    expect(extraction.payloadHash).toMatch(/^[0-9a-f]{64}$/);
    expect(extraction.schemaError).toBeNull();
    expect(extraction.metadata.imageUrls.length).toBeGreaterThan(0);
    expect(extraction.metadata.imageUrls.every((imageUrl) => /^https?:\/\//.test(imageUrl))).toBe(true);
  });
});
