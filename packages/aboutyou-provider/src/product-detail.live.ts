import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { chromium, type BrowserContext, type Browser } from "playwright";
import { fetchProductDetail } from "./index";

const productCases = [
  ["32237548", "https://www.aboutyou.lt/p/vans/sportbaciai-be-auliuko-32237548"],
  ["32190350", "https://www.aboutyou.lt/p/calvin-klein-underwear/kelnaites-paaukstintu-liemeniu-32190350"],
  ["15135978", "https://www.aboutyou.lt/p/calvin-klein-underwear/moteriskos-kelnaites-15135978"]
] as const;

describe("live ABOUT YOU metadata sync product pages", () => {
  let browser: Browser;
  let context: BrowserContext;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  });

  afterAll(async () => {
    await browser.close();
  });

  it.each(productCases)("parses product %s with images", async (externalId, url) => {
    const response = await fetchProductDetail(context, url);

    expect(response.status).toBe(200);
    const finalUrl = new URL(response.finalUrl);
    expect(finalUrl.pathname).toMatch(new RegExp(`-${externalId}/?$`));

    const extraction = response.extraction;
    expect(extraction.sourceProductId).toBe(externalId);
    expect(extraction.rawPayload).not.toBeNull();
    expect(extraction.payloadHash).toMatch(/^[0-9a-f]{64}$/);
    expect(extraction.schemaError).toBeNull();
    expect(extraction.metadata.imageUrls.length).toBeGreaterThan(0);
    expect(extraction.metadata.imageUrls.every((imageUrl) => /^https?:\/\//.test(imageUrl))).toBe(true);
  });
});
