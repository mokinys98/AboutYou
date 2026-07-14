// ==UserScript==
// @name         ABOUT YOU price sorter
// @namespace    local.aboutyou.price-sort
// @version      0.1.9
// @description  Sort ABOUT YOU product grids by current price or lowest prior price, highlight products where current price is at least the last lowest price, and export prices to CSV.
// @match        *://www.aboutyou.lt/*
// @match        *://aboutyou.lt/*
// @match        *://*.aboutyou.lt/*
// @include      https://www.aboutyou.lt/*
// @include      https://aboutyou.lt/*
// @include      https://*.aboutyou.lt/*
// @run-at       document-start
// @noframes
// @grant        none
// ==/UserScript==

(function () {
  "use strict";

  if (window.__ABOUTYOU_PRICE_SORTER_LOADED__) return;
  console.warn("[ABOUT YOU price sorter] userscript loaded", location.href);
  window.__ABOUTYOU_PRICE_SORTER_LOADED__ = true;

  const PRODUCT_PATH_RE = /\/p\/[^?#]+-(\d+)(?:[?#]|$)/;
  const TADARIDA_HOST_RE = /:\/\/tadarida-web\.aboutyou\.com\b/;
  const PRODUCT_STREAM_SERVICE = "aysa_api.services.category_page.v1.stream.CategoryStreamService";
  const PRODUCT_STREAM_INITIAL_METHOD = "GetProductStreamV2";
  const PRODUCT_STREAM_INITIAL_PATH = `${PRODUCT_STREAM_SERVICE}/${PRODUCT_STREAM_INITIAL_METHOD}`;
  const PRODUCT_STREAM_PAGE_METHOD = "GetProductStreamPageV2";
  const PRODUCT_STREAM_PAGE_PATH = `${PRODUCT_STREAM_SERVICE}/${PRODUCT_STREAM_PAGE_METHOD}`;
  const CATEGORY_STREAM_MODULE_FALLBACK = "https://assets.aboutstatic.com/assets/service.grpc-DpEGTlTl.js";
  const DIRECT_ALL_MAX_PAGES = 200;
  const STATE = {
    products: new Map(),
    cards: [],
    grid: null,
    filterCheaperThanLpl: false,
    loadingAll: false,
    stopLoading: false,
    applyingDomChanges: false,
    pageKey: getPageKey(),
    initialPageKey: getPageKey(),
    stream: {
      nextState: null,
      total: null,
      basketToken: null,
      preferredProductImageType: undefined,
      sortingChannel: undefined,
      moduleUrl: "",
      modulePromise: null,
      learnedRequest: null,
      directError: "",
      pages: 0,
    },
    staticConfig: null,
  };

  const css = `
    #ay-price-tools {
      position: fixed;
      top: 88px;
      right: 16px;
      z-index: 2147483647;
      display: flex;
      flex-direction: column;
      gap: 8px;
      width: 280px;
      padding: 12px;
      color: #111;
      background: rgba(255, 255, 255, 0.96);
      border: 1px solid #d8d8d8;
      border-radius: 6px;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.16);
      font: 12px/1.35 Arial, sans-serif;
    }
    #ay-price-tools strong {
      font-size: 13px;
    }
    #ay-price-tools button {
      min-height: 30px;
      padding: 6px 8px;
      border: 1px solid #bdbdbd;
      border-radius: 4px;
      background: #fff;
      color: #111;
      cursor: pointer;
      font: inherit;
      text-align: left;
    }
    #ay-price-tools button:hover {
      background: #f2f2f2;
    }
    #ay-price-tools button[data-active="true"] {
      border-color: #111;
      background: #111;
      color: #fff;
    }
    #ay-price-tools button[data-action="stop-loading"] {
      border-color: #d9232a;
      color: #d9232a;
      font-weight: 700;
    }
    #ay-price-tools button[data-action="stop-loading"]:disabled {
      opacity: 0.45;
      cursor: not-allowed;
    }
    #ay-price-tools .ay-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px;
    }
    #ay-price-tools .ay-status {
      color: #555;
      min-height: 16px;
    }
    #ay-price-tools details {
      border-top: 1px solid #e4e4e4;
      padding-top: 6px;
    }
    #ay-price-tools summary {
      cursor: pointer;
      font-weight: 700;
    }
    #ay-price-results {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 360px;
      overflow: auto;
      padding-top: 6px;
    }
    #ay-price-results a {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 4px 8px;
      padding: 6px;
      color: inherit;
      text-decoration: none;
      border: 1px solid #e2e2e2;
      border-radius: 4px;
      background: #fff;
    }
    #ay-price-results a:hover {
      background: #f7f7f7;
    }
    #ay-price-results .ay-result-name {
      grid-column: 1 / -1;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-weight: 700;
    }
    #ay-price-results .ay-result-brand,
    #ay-price-results .ay-result-lpl {
      color: #666;
    }
    #ay-price-results .ay-result-delta[data-good="true"] {
      color: #0a7a24;
      font-weight: 700;
    }
    #ay-price-results .ay-result-delta[data-good="false"] {
      color: #b00020;
      font-weight: 700;
    }
    .ay-lpl-badge {
      position: absolute;
      top: 8px;
      left: 8px;
      z-index: 20;
      max-width: calc(100% - 16px);
      padding: 4px 6px;
      border-radius: 4px;
      color: #fff;
      background: #111;
      font: 700 11px/1.25 Arial, sans-serif;
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.28);
      pointer-events: none;
    }
    .ay-lpl-badge[data-over="true"] {
      background: #d9232a;
    }
    .ay-hidden-by-lpl-filter {
      display: none !important;
    }
  `;

  function installStyles() {
    if (document.getElementById("ay-price-tools-style")) return;
    const style = document.createElement("style");
    style.id = "ay-price-tools-style";
    style.textContent = css;
    document.head.appendChild(style);
  }

  function stripHtml(value) {
    if (!value) return "";
    const div = document.createElement("div");
    div.innerHTML = String(value);
    return div.textContent || "";
  }

  function parsePriceText(value) {
    const text = stripHtml(value).replace(/\u00a0/g, " ");
    const match = text.match(/(\d{1,4}(?:[ .]\d{3})*|\d+)(?:[,.](\d{1,2}))?\s*€/);
    if (!match) return null;
    const euros = match[1].replace(/[ .]/g, "");
    const cents = (match[2] || "00").padEnd(2, "0").slice(0, 2);
    const parsed = Number(euros) * 100 + Number(cents);
    return Number.isFinite(parsed) ? parsed : null;
  }

  function formatPrice(cents) {
    if (!Number.isFinite(cents)) return "";
    return `${(cents / 100).toFixed(2).replace(".", ",")} €`;
  }

  function productUrl(url) {
    if (!url) return "";
    try {
      return new URL(url, location.origin).href;
    } catch (_) {
      return url;
    }
  }

  function productIdFromUrl(url) {
    const match = String(url || "").match(PRODUCT_PATH_RE);
    return match ? Number(match[1]) : null;
  }

  function normalizeLplPrice(value, fallbackPrice) {
    if (Number.isFinite(value)) return value;
    return Number.isFinite(fallbackPrice) ? fallbackPrice : 0;
  }

  function isFallbackLplPrice(value) {
    return !Number.isFinite(value);
  }

  function getPageKey() {
    return `${location.pathname}${location.search}`;
  }

  function ensurePageContext() {
    const pageKey = getPageKey();
    if (STATE.pageKey === pageKey) return false;
    resetCollectedState();
    STATE.pageKey = pageKey;
    updateStatus("Naujas puslapis aptiktas, rezultatai isvalyti.");
    return true;
  }

  function resetCollectedState() {
    STATE.stopLoading = true;
    STATE.loadingAll = false;
    STATE.products.clear();
    STATE.cards = [];
    STATE.grid = null;
    STATE.filterCheaperThanLpl = false;
    STATE.stream.nextState = null;
    STATE.stream.total = null;
    STATE.stream.basketToken = null;
    STATE.stream.preferredProductImageType = undefined;
    STATE.stream.sortingChannel = undefined;
    STATE.stream.moduleUrl = "";
    STATE.stream.modulePromise = null;
    STATE.stream.learnedRequest = null;
    STATE.stream.directError = "";
    STATE.stream.pages = 0;

    for (const badge of document.querySelectorAll(".ay-lpl-badge")) {
      badge.remove();
    }
    for (const element of document.querySelectorAll(".ay-hidden-by-lpl-filter")) {
      element.classList.remove("ay-hidden-by-lpl-filter");
    }

    renderResults();
    updateActiveButtons();
  }

  function installFetchObserver() {
    if (window.__ABOUTYOU_PRICE_SORTER_FETCH_OBSERVER__) return;
    window.__ABOUTYOU_PRICE_SORTER_FETCH_OBSERVER__ = true;
    const originalFetch = window.fetch;
    if (typeof originalFetch !== "function") return;

    window.fetch = function ayObservedFetch(input, init) {
      try {
        rememberTadaridaRequest(input, init);
      } catch (_) {
        // Observing network shape should never affect the shop.
      }
      return originalFetch.apply(this, arguments);
    };
  }

  function rememberTadaridaRequest(input, init) {
    const request = input instanceof Request ? input : null;
    const url = request ? request.url : String(input || "");
    if (!TADARIDA_HOST_RE.test(url)) return;

    const headers = new Headers(request?.headers || init?.headers || {});
    STATE.stream.learnedRequest = {
      url,
      headers: Array.from(headers.entries()),
      credentials: init?.credentials || request?.credentials || "include",
      mode: init?.mode || request?.mode || "cors",
      referrerPolicy: init?.referrerPolicy || request?.referrerPolicy || "strict-origin-when-cross-origin",
    };
  }

  installFetchObserver();

  function upsertProduct(product) {
    if (!product || !product.productId) return;
    const existing = STATE.products.get(product.productId) || {};
    const next = { ...existing, ...compact(product) };
    if (existing.name && !product.brand) next.name = existing.name;
    if (existing.imageUrls?.length || product.imageUrls?.length) {
      next.imageUrls = Array.from(new Set([...(existing.imageUrls || []), ...(product.imageUrls || [])])).slice(0, 6);
    }
    if (
      product.lplIsFallback &&
      existing.lplIsFallback === false &&
      Number.isFinite(existing.lplPrice)
    ) {
      next.lplPrice = existing.lplPrice;
      next.lplIsFallback = false;
    }
    STATE.products.set(product.productId, next);
    scheduleRenderResults();
  }

  function compact(object) {
    return Object.fromEntries(
      Object.entries(object).filter(([, value]) => value !== null && value !== undefined && value !== "")
    );
  }

  function productFromTile(tile) {
    const priceV2 = tile.priceV2 || {};
    const tracker = tile.price?.tracker || priceV2.tracker || {};
    const currentPrice =
      tile.price?.price?.amount ??
      tracker.price ??
      parsePriceText(priceV2.finalPrice?.priceLabel?.text);
    const originalPrice =
      tracker.fullPrice ??
      parsePriceText(priceV2.original?.text);
    const rawLplPrice =
      parsePriceText(priceV2.lpl30d?.value?.text) ??
      parsePriceText(tile.price?.lpl30);
    const lplPrice = normalizeLplPrice(rawLplPrice, currentPrice);

    return {
      productId: tile.productId,
      name: tile.productTracker?.productName || "",
      url: productUrl(tile.link?.url || tile.productTracker?.linkTarget),
      currentPrice,
      originalPrice,
      lplPrice,
      lplIsFallback: isFallbackLplPrice(rawLplPrice),
      brand: tile.brandName || tile.brandTracker?.name || "",
      imageUrls: findImageUrls(tile),
      colorOriginal: findString(tile, ["colorLabel", "colorName", "color", "displayColor", "baseColor"]) || null,
      categories: findStrings(tile, ["category", "categoryName", "categoryNames", "categories"]),
      sizes: findStrings(tile, ["availableSizes", "sizeLabels", "sizes"]),
      otherSizes: findStrings(tile, ["otherSizes", "specialSizes", "sizeGroups"]),
      materials: findStrings(tile, ["material", "materials", "materialName", "materialComposition"]),
      patterns: findStrings(tile, ["pattern", "patterns", "patternName"]),
      features: findStrings(tile, ["features", "productFeatures", "attributes"]),
      styles: findStrings(tile, ["style", "styles", "styleName"]),
      productTypes: findStrings(tile, ["productType", "productTypes", "productTypeName"]),
    };
  }

  function findString(value, keys) {
    if (!value || typeof value !== "object") return "";
    for (const key of keys) {
      if (typeof value[key] === "string") return value[key];
    }
    for (const child of Object.values(value)) {
      const found = findString(child, keys);
      if (found) return found;
    }
    return "";
  }

  function findStrings(value, keys) {
    const wanted = new Set(keys);
    const values = new Set();
    const add = (item) => {
      if (typeof item === "string") {
        const text = item.replace(/\s+/g, " ").trim();
        if (text && text.length <= 100 && !/^https?:/i.test(text)) values.add(text);
      } else if (Array.isArray(item)) {
        item.forEach(add);
      } else if (item && typeof item === "object") {
        add(item.label ?? item.name ?? item.value ?? item.text);
      }
    };
    const visit = (item) => {
      if (!item || typeof item !== "object") return;
      for (const [key, child] of Object.entries(item)) {
        if (wanted.has(key)) add(child);
        if (child && typeof child === "object") visit(child);
      }
    };
    visit(value);
    return Array.from(values).slice(0, 30);
  }

  function findImageUrls(value) {
    const urls = new Set();
    const visit = (item) => {
      if (typeof item === "string" && /^https:\/\//.test(item) && /\.(?:jpe?g|webp|avif)(?:\?|$)/i.test(item)) {
        urls.add(item);
      } else if (Array.isArray(item)) {
        item.forEach(visit);
      } else if (item && typeof item === "object") {
        Object.values(item).forEach(visit);
      }
    };
    visit(value);
    return Array.from(urls).slice(0, 6);
  }

  function parseInitialState() {
    ensurePageContext();
    if (STATE.pageKey !== STATE.initialPageKey) return;

    for (const script of document.querySelectorAll('script[data-tadarida-initial-state="true"]')) {
      let entries;
      try {
        entries = JSON.parse(script.textContent || "[]", reviveTadaridaValue);
      } catch (_) {
        continue;
      }

      if (!Array.isArray(entries)) continue;
      for (const entry of entries) {
        const key = String(entry?.[0] || "");
        const payload = entry?.[1];
        const data = payload?.data || payload;
        if (!key.includes(PRODUCT_STREAM_INITIAL_PATH)) continue;
        collectProductTiles(data, (tile) => upsertProduct(productFromTile(tile)));
        rememberProductStreamState(data);
      }
    }
  }

  function reviveTadaridaValue(key, value) {
    const isLegacyByteArray = value?.__type === "_Uint8Array_";
    const isCurrentNextState = key === "nextState" && value && !value.__type;
    if (
      (isLegacyByteArray || isCurrentNextState) &&
      Array.isArray(value.data) &&
      value.data.every((byte) => Number.isInteger(byte) && byte >= 0 && byte <= 255)
    ) {
      return new Uint8Array(value.data);
    }
    return value;
  }

  function rememberProductStreamState(data) {
    if (!data || typeof data !== "object") return;
    if (data.nextState instanceof Uint8Array && data.nextState.length > 0) {
      STATE.stream.nextState = data.nextState;
    }
    if (Number.isFinite(data.pagination?.total)) {
      STATE.stream.total = data.pagination.total;
    }
    if (data.basketToken) {
      STATE.stream.basketToken = data.basketToken;
    }
    if (data.preferredProductImageType !== undefined) {
      STATE.stream.preferredProductImageType = data.preferredProductImageType;
    }
    if (data.trackingData?.sortingChannel) {
      STATE.stream.sortingChannel = data.trackingData.sortingChannel;
    }
  }

  function collectProductTiles(value, onTile) {
    if (!value || typeof value !== "object") return;
    if (value.productTile?.productId) onTile(value.productTile);
    if (value.type?.productSection?.productTile?.productId) onTile(value.type.productSection.productTile);
    if (Array.isArray(value)) {
      for (const item of value) collectProductTiles(item, onTile);
      return;
    }
    for (const child of Object.values(value)) collectProductTiles(child, onTile);
  }

  function findCard(anchor) {
    let best = null;
    let node = anchor;
    for (let depth = 0; node && node !== document.body && depth < 8; depth += 1, node = node.parentElement) {
      if (!(node instanceof HTMLElement)) continue;
      const rect = node.getBoundingClientRect();
      const text = node.textContent || "";
      const productLinks = node.querySelectorAll('a[href*="/p/"]').length;
      if (rect.width >= 120 && rect.height >= 160 && text.includes("€") && productLinks <= 8) {
        best = node;
      }
    }
    return best || anchor.closest("article, li") || anchor.parentElement;
  }

  function productFromCard(card, anchor) {
    const href = anchor.getAttribute("href") || anchor.href;
    const id = productIdFromUrl(href);
    if (!id) return null;

    const cardForText = card.cloneNode(true);
    for (const badge of cardForText.querySelectorAll(".ay-lpl-badge")) {
      badge.remove();
    }
    const text = cardForText.textContent || "";
    const prices = Array.from(text.matchAll(/(\d{1,4}(?:[ .]\d{3})*|\d+)(?:[,.](\d{1,2}))?\s*€/g))
      .map((match) => parsePriceText(match[0]))
      .filter((price) => price !== null);
    const lplMatch = text.match(/Paskutinė\s+mažiausia\s+kaina\D+(\d{1,4}(?:[ .]\d{3})*|\d+)(?:[,.](\d{1,2}))?\s*€/i);
    const originalMatch = text.match(/Pradinė\s+kaina\D+(\d{1,4}(?:[ .]\d{3})*|\d+)(?:[,.](\d{1,2}))?\s*€/i);

    const currentPrice = resolveDomCurrentPrice(prices, originalMatch, lplMatch);
    const rawLplPrice = lplMatch ? parsePriceText(lplMatch[0]) : null;

    return {
      productId: id,
      url: productUrl(href),
      currentPrice,
      originalPrice: originalMatch ? parsePriceText(originalMatch[0]) : null,
      lplPrice: normalizeLplPrice(rawLplPrice, currentPrice),
      lplIsFallback: isFallbackLplPrice(rawLplPrice),
      name: guessName(card),
    };
  }

  function resolveDomCurrentPrice(prices, originalMatch, lplMatch) {
    const originalPrice = originalMatch ? parsePriceText(originalMatch[0]) : null;
    const lplPrice = lplMatch ? parsePriceText(lplMatch[0]) : null;
    const uniquePrices = [...new Set(prices)];
    const nonMetaPrices = uniquePrices.filter((price) => price !== originalPrice && price !== lplPrice);
    if (nonMetaPrices.length > 0) return nonMetaPrices[0];
    return prices[0] ?? null;
  }

  function guessName(card) {
    const candidates = Array.from(card.querySelectorAll('[aria-label], img[alt], a[href*="/p/"]'));
    for (const element of candidates) {
      const value =
        element.getAttribute("aria-label") ||
        element.getAttribute("alt") ||
        element.textContent;
      const cleaned = String(value || "").replace(/\s+/g, " ").trim();
      if (
        cleaned &&
        !cleaned.includes("€") &&
        !/^Pereiti prie detalaus aprašymo$/i.test(cleaned) &&
        cleaned.length > 3
      ) return cleaned;
    }
    return "";
  }

  function scanCards() {
    if (ensurePageContext()) return;
    const seenCards = new Set();
    const cards = [];

    for (const anchor of document.querySelectorAll('a[href*="/p/"]')) {
      const id = productIdFromUrl(anchor.getAttribute("href") || anchor.href);
      if (!id) continue;
      const card = findCard(anchor);
      if (!card || seenCards.has(card)) continue;
      seenCards.add(card);
      upsertProduct(productFromCard(card, anchor));
      cards.push({ productId: id, element: card });
    }

    const byParent = new Map();
    for (const card of cards) {
      const parent = card.element.parentElement;
      if (!parent) continue;
      if (!byParent.has(parent)) byParent.set(parent, []);
      byParent.get(parent).push(card);
    }

    const largest = Array.from(byParent.entries()).sort((a, b) => b[1].length - a[1].length)[0];
    STATE.grid = largest?.[0] || null;
    STATE.cards = largest?.[1] || cards;
    decorateCards();
    updateStatus();
  }

  function productForCard(card) {
    return STATE.products.get(card.productId) || {};
  }

  function decorateCards() {
    for (const card of STATE.cards) {
      const product = productForCard(card);
      const existing = card.element.querySelector(":scope > .ay-lpl-badge");
      if (!Number.isFinite(product.lplPrice)) {
        if (existing) existing.remove();
        continue;
      }

      const hasCurrentPrice = Number.isFinite(product.currentPrice);
      const over = hasCurrentPrice && product.currentPrice > product.lplPrice;
      const delta = hasCurrentPrice ? product.currentPrice - product.lplPrice : null;
      const diff = Number.isFinite(delta) ? ` / dabar ${delta > 0 ? "+" : ""}${formatPrice(delta)}` : "";
      const badge = existing || document.createElement("div");
      badge.className = "ay-lpl-badge";
      badge.dataset.over = String(over);
      badge.textContent = `LPL: ${formatPrice(product.lplPrice)}${diff}`;
      if (!existing) {
        const position = getComputedStyle(card.element).position;
        if (position === "static") card.element.style.position = "relative";
        card.element.prepend(badge);
      }
    }
    applyFilter();
  }

  function applyFilter() {
    for (const card of STATE.cards) {
      const product = productForCard(card);
      const cheaper = Number.isFinite(product.currentPrice) &&
        Number.isFinite(product.lplPrice) &&
        product.currentPrice < product.lplPrice;
      card.element.classList.toggle("ay-hidden-by-lpl-filter", STATE.filterCheaperThanLpl && !cheaper);
    }
    if (STATE.filterCheaperThanLpl) sortCheaperCardsByDelta();
  }

  function sortCheaperCardsByDelta() {
    if (!STATE.grid) return;
    const visibleCheaperCards = STATE.cards
      .filter((card) => !card.element.classList.contains("ay-hidden-by-lpl-filter"))
      .sort((left, right) => priceDelta(left) - priceDelta(right));

    STATE.applyingDomChanges = true;
    for (const card of visibleCheaperCards) {
      STATE.grid.appendChild(card.element);
    }
    setTimeout(() => {
      STATE.applyingDomChanges = false;
    }, 0);
  }

  function priceDelta(card) {
    const product = productForCard(card);
    if (!Number.isFinite(product.currentPrice) || !Number.isFinite(product.lplPrice)) return Infinity;
    return product.currentPrice - product.lplPrice;
  }

  async function loadProductsByScroll(targetCount) {
    let stableRounds = 0;
    let previousCount = 0;
    const maxRounds = Number.isFinite(targetCount) ? 40 : 120;
    for (let round = 0; round < maxRounds && stableRounds < 5; round += 1) {
      if (STATE.stopLoading) break;
      scanCards();
      const count = Math.max(STATE.cards.length, STATE.products.size);
      if (Number.isFinite(targetCount) && count >= targetCount) break;
      stableRounds = count === previousCount ? stableRounds + 1 : 0;
      previousCount = count;
      window.scrollTo(0, document.documentElement.scrollHeight);
      updateStatus(`Scroll fallback: ${STATE.products.size} duomenu, ${STATE.cards.length} DOM...`);
      await sleep(450);
    }

    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function loadProductsFast(targetCount) {
    parseInitialState();
    scanCards();
    if (!(STATE.stream.nextState instanceof Uint8Array) || STATE.stream.nextState.length === 0) {
      throw new Error("Product stream nextState nerastas initial-state duomenyse.");
    }

    let page = 0;
    let stablePages = 0;
    const initialCount = STATE.products.size;
    if (Number.isFinite(targetCount) && initialCount >= targetCount) return true;
    const effectiveTarget = Number.isFinite(targetCount) && Number.isFinite(STATE.stream.total)
      ? Math.min(targetCount, STATE.stream.total)
      : targetCount;
    const maxPages = Number.isFinite(effectiveTarget)
      ? Math.max(1, Math.ceil(Math.max(0, effectiveTarget - initialCount) / 24) + 12)
      : DIRECT_ALL_MAX_PAGES;

    while (!STATE.stopLoading && STATE.stream.nextState && page < maxPages) {
      if (Number.isFinite(targetCount) && STATE.products.size >= targetCount) break;
      page += 1;
      STATE.stream.pages = page;
      let response;
      let pageError;
      for (let attempt = 1; attempt <= 4; attempt += 1) {
        try {
          response = await fetchNextProductStreamPage();
          pageError = null;
          break;
        } catch (error) {
          pageError = error;
          if (attempt < 4) await sleep(500 * 2 ** (attempt - 1));
        }
      }
      if (pageError) throw pageError;
      if (!response?.items?.length) break;
      const countBeforePage = STATE.products.size;
      collectProductTiles(response, (tile) => upsertProduct(productFromTile(tile)));
      stablePages = STATE.products.size === countBeforePage ? stablePages + 1 : 0;
      if (!(response.nextState instanceof Uint8Array) || response.nextState.length === 0) {
        STATE.stream.nextState = null;
      }
      rememberProductStreamState(response);
      renderResults();
      updateStatus(`Direct stream: ${STATE.products.size} duomenu, ${STATE.cards.length} DOM...`);
      if (stablePages >= 3) {
        STATE.stream.nextState = null;
        break;
      }
      await sleep(60);
    }

    return STATE.products.size > initialCount;
  }

  async function loadProducts(targetCount) {
    ensurePageContext();
    if (STATE.loadingAll) return;
    STATE.loadingAll = true;
    STATE.stopLoading = false;
    const restoreFilterAfterLoad = STATE.filterCheaperThanLpl;
    STATE.filterCheaperThanLpl = false;
    applyFilter();
    updateActiveButtons();
    const targetLabel = Number.isFinite(targetCount) ? `${targetCount}` : "visos";
    updateStatus(`Kraunama iki ${targetLabel}...`);

    let usedFallback = false;
    try {
      await loadProductsFast(targetCount);
    } catch (error) {
      usedFallback = true;
      STATE.stream.modulePromise = null;
      STATE.stream.directError = error?.message || String(error);
      console.warn("[ABOUT YOU price sorter] direct stream failed, falling back to scroll", error);
      updateStatus(`Direct nepavyko, jungiamas scroll fallback...`);
      await sleep(400);
      if (!STATE.stopLoading) await loadProductsByScroll(targetCount);
    }

    const wasStopped = STATE.stopLoading;
    STATE.loadingAll = false;
    STATE.stopLoading = false;
    STATE.filterCheaperThanLpl = restoreFilterAfterLoad;
    updateActiveButtons();
    scanCards();
    applyFilter();
    renderResults();
    if (wasStopped) {
      updateStatus("Krovimas sustabdytas.");
    } else if (usedFallback) {
      updateStatus(`Baigta per scroll fallback. ${STATE.stream.directError}`);
    } else {
      updateStatus();
    }
  }

  function collectionSnapshot() {
    const expectedTotal = Number.isFinite(STATE.stream.total) ? STATE.stream.total : null;
    const requestedTotal = Number.isFinite(STATE.collectionTarget) ? STATE.collectionTarget : expectedTotal;
    const targetTotal = Number.isFinite(requestedTotal) && Number.isFinite(expectedTotal)
      ? Math.min(requestedTotal, expectedTotal)
      : requestedTotal;
    return {
      products: Array.from(STATE.products.values()),
      productCount: STATE.products.size,
      expectedTotal,
      pages: STATE.stream.pages,
      loading: STATE.loadingAll,
      mode: STATE.stream.directError ? "scroll-fallback" : "direct-stream",
      complete: Number.isFinite(targetTotal)
        ? STATE.products.size >= targetTotal || !STATE.stream.nextState
        : !STATE.stream.nextState,
      error: STATE.stream.directError || null,
    };
  }

  window.__ABOUTYOU_CATALOG_COLLECTOR__ = {
    snapshot: collectionSnapshot,
    async collect(targetCount) {
      STATE.collectionTarget = targetCount;
      await loadProducts(targetCount);
      return collectionSnapshot();
    },
  };

  async function fetchNextProductStreamPage() {
    const service = await loadCategoryStreamService();
    let response;
    const client = {
      unary(descriptor, request, options) {
        return callGrpcWebUnary(descriptor, request, options);
      },
    };

    response = await service(client, {
      session: getSessionPayload(),
      reductionsState: {},
      basketToken: STATE.stream.basketToken || undefined,
      streamState: STATE.stream.nextState,
      preferredProductImageType: STATE.stream.preferredProductImageType,
      sortingChannel: STATE.stream.sortingChannel,
    });

    return response;
  }

  async function loadCategoryStreamService() {
    if (!STATE.stream.modulePromise) {
      STATE.stream.modulePromise = (async () => {
        const moduleUrl = await resolveCategoryStreamModuleUrl();
        STATE.stream.moduleUrl = moduleUrl;
        const mod = await import(moduleUrl);
        const service = mod.CategoryStreamService_GetProductStreamPageV2;
        if (typeof service !== "function") {
          throw new Error("CategoryStreamService_GetProductStreamPageV2 export nerastas.");
        }
        return service;
      })();
    }
    return STATE.stream.modulePromise;
  }

  async function resolveCategoryStreamModuleUrl() {
    if (STATE.stream.moduleUrl) return STATE.stream.moduleUrl;
    const indexScript = Array.from(document.scripts)
      .map((script) => script.src)
      .find((src) => /\/assets\/index-[^/]+\.js/.test(src));
    if (!indexScript) return CATEGORY_STREAM_MODULE_FALLBACK;

    try {
      const code = await fetch(indexScript, { credentials: "omit" }).then((response) => response.text());
      const match = code.match(/import\("\.\/(service\.grpc-[^"]+\.js)"\)[\s\S]{0,260}?CategoryStreamService_GetProductStreamPageV2/);
      if (match) return new URL(match[1], indexScript).href;
      const categoryMatch = code.match(/assets\/CategoryLegacy\.eager-[^"]+\.js/);
      if (categoryMatch) {
        const categoryUrl = new URL(categoryMatch[0].replace(/^assets\//, ""), indexScript).href;
        const categoryCode = await fetch(categoryUrl, { credentials: "omit" }).then((response) => response.text());
        const serviceMatch = categoryCode.match(/import\("\.\/(service\.grpc-[^"]+\.js)"\)[\s\S]{0,320}?CategoryStreamService_GetProductStreamPageV2/);
        if (serviceMatch) return new URL(serviceMatch[1], categoryUrl).href;
      }
    } catch (error) {
      console.warn("[ABOUT YOU price sorter] failed to discover category stream module", error);
    }
    return CATEGORY_STREAM_MODULE_FALLBACK;
  }

  async function callGrpcWebUnary(descriptor, request, options) {
    const requestPayload = {
      ...request,
      config: getGrpcConfig(),
      session: request.session || getSessionPayload(),
      reductionsState: request.reductionsState || {},
    };
    const writer = ProtoWriter.create();
    descriptor.encodeRequest(writer, requestPayload);
    const requestBytes = writer.finish();
    const response = await fetch(resolveGrpcUrl(descriptor), {
      method: "POST",
      credentials: STATE.stream.learnedRequest?.credentials || "include",
      mode: STATE.stream.learnedRequest?.mode || "cors",
      referrerPolicy: STATE.stream.learnedRequest?.referrerPolicy || "strict-origin-when-cross-origin",
      headers: buildGrpcHeaders(options),
      body: encodeGrpcWebFrame(requestBytes),
    });

    if (!response.ok) {
      throw new Error(`Tadarida ${descriptor.methodName} HTTP ${response.status}`);
    }

    const bytes = new Uint8Array(await response.arrayBuffer());
    const messageBytes = decodeGrpcWebResponse(bytes);
    if (!messageBytes.length) {
      throw new Error(`Tadarida ${descriptor.methodName} atsakymas tuscias.`);
    }
    return descriptor.decodeResponse(new ProtoReader(messageBytes), messageBytes.length);
  }

  function resolveGrpcUrl(descriptor) {
    const learned = STATE.stream.learnedRequest?.url;
    if (learned && learned.includes(PRODUCT_STREAM_PAGE_PATH)) return learned;
    if (learned) {
      const serviceIndex = learned.indexOf("/aysa_api.services.");
      if (serviceIndex !== -1) {
        return `${learned.slice(0, serviceIndex)}/${descriptor.serviceName}/${descriptor.methodName}`;
      }
    }
    const config = getStaticConfig();
    const host = config?.hostConfig?.tadaridaUrl || "https://tadarida-web.aboutyou.com";
    return `${host}/${descriptor.serviceName}/${descriptor.methodName}`;
  }

  function buildGrpcHeaders(options) {
    const headers = new Headers();
    for (const [key, value] of STATE.stream.learnedRequest?.headers || []) {
      const normalized = key.toLowerCase();
      if (["accept", "authorization", "x-ay-active-ab-tests", "x-customer-token", "x-tadarida-considered-ab-tests"].includes(normalized)) {
        headers.set(key, value);
      }
    }
    headers.set("content-type", "application/grpc-web+proto");
    headers.set("accept", "application/grpc-web+proto");
    headers.set("x-grpc-web", "1");
    headers.set("x-user-agent", "grpc-web-javascript/0.1");
    const metadata = options?.metadata;
    if (metadata && typeof metadata.forEach === "function") {
      metadata.forEach((value, key) => headers.set(key, value));
    }
    return headers;
  }

  function getStaticConfig() {
    if (STATE.staticConfig) return STATE.staticConfig;
    const script = document.querySelector("[data-tadarida-static-config]");
    if (!script) return null;
    try {
      STATE.staticConfig = JSON.parse(script.textContent || "{}");
      return STATE.staticConfig;
    } catch (_) {
      return null;
    }
  }

  function getGrpcConfig() {
    const grpcConfig = getStaticConfig()?.grpcConfig || {};
    return {
      country: grpcConfig.country ?? 13,
      language: grpcConfig.language ?? 11,
      device: grpcConfig.device ?? 1,
      clientVersion: grpcConfig.clientVersion || document.querySelector('meta[name="version"]')?.content || "",
      abTests: Array.isArray(grpcConfig.abTests) ? grpcConfig.abTests : [],
    };
  }

  function getSessionPayload() {
    return {};
  }

  function encodeGrpcWebFrame(messageBytes) {
    const frame = new Uint8Array(5 + messageBytes.length);
    frame[0] = 0;
    frame[1] = (messageBytes.length >>> 24) & 255;
    frame[2] = (messageBytes.length >>> 16) & 255;
    frame[3] = (messageBytes.length >>> 8) & 255;
    frame[4] = messageBytes.length & 255;
    frame.set(messageBytes, 5);
    return frame;
  }

  function decodeGrpcWebResponse(bytes) {
    if (bytes.length < 5) return bytes;
    let offset = 0;
    const chunks = [];
    while (offset + 5 <= bytes.length) {
      const flags = bytes[offset];
      const length =
        bytes[offset + 1] * 16777216 +
        bytes[offset + 2] * 65536 +
        bytes[offset + 3] * 256 +
        bytes[offset + 4];
      offset += 5;
      if (length < 0 || offset + length > bytes.length) break;
      if ((flags & 128) === 0) {
        chunks.push(bytes.slice(offset, offset + length));
      }
      offset += length;
    }
    if (chunks.length === 0) return new Uint8Array();
    if (chunks.length === 1) return chunks[0];
    const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
    const merged = new Uint8Array(total);
    let position = 0;
    for (const chunk of chunks) {
      merged.set(chunk, position);
      position += chunk.length;
    }
    return merged;
  }

  class ProtoWriter {
    constructor() {
      this.chunks = [];
      this.stack = [];
    }

    static create() {
      return new ProtoWriter();
    }

    uint32(value) {
      this.writeVarint(BigInt(value >>> 0));
      return this;
    }

    int32(value) {
      this.writeVarint(BigInt(value >>> 0));
      return this;
    }

    sint32(value) {
      const number = Number(value || 0);
      return this.uint32((number << 1) ^ (number >> 31));
    }

    int64(value) {
      this.writeVarint(BigInt(value || 0));
      return this;
    }

    uint64(value) {
      return this.int64(value);
    }

    sint64(value) {
      const number = BigInt(value || 0);
      const encoded = (number << 1n) ^ (number >> 63n);
      this.writeVarint(encoded);
      return this;
    }

    bool(value) {
      return this.uint32(value ? 1 : 0);
    }

    string(value) {
      const bytes = new TextEncoder().encode(String(value || ""));
      this.uint32(bytes.length);
      this.raw(bytes);
      return this;
    }

    bytes(value) {
      const bytes = value instanceof Uint8Array ? value : new Uint8Array(value || []);
      this.uint32(bytes.length);
      this.raw(bytes);
      return this;
    }

    fork() {
      this.stack.push(this.chunks);
      this.chunks = [];
      return this;
    }

    ldelim() {
      const child = this.finish();
      this.chunks = this.stack.pop() || [];
      this.uint32(child.length);
      this.raw(child);
      return this;
    }

    finish() {
      const total = this.chunks.reduce((sum, chunk) => sum + chunk.length, 0);
      const output = new Uint8Array(total);
      let offset = 0;
      for (const chunk of this.chunks) {
        output.set(chunk, offset);
        offset += chunk.length;
      }
      return output;
    }

    raw(bytes) {
      this.chunks.push(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes));
      return this;
    }

    writeVarint(value) {
      let current = BigInt.asUintN(64, value);
      const bytes = [];
      while (current > 127n) {
        bytes.push(Number((current & 127n) | 128n));
        current >>= 7n;
      }
      bytes.push(Number(current));
      this.raw(new Uint8Array(bytes));
    }
  }

  class ProtoReader {
    constructor(bytes) {
      this.buf = bytes;
      this.pos = 0;
      this.len = bytes.length;
    }

    uint32() {
      return Number(this.readVarint());
    }

    int32() {
      return this.uint32() | 0;
    }

    int64() {
      const value = this.readVarint();
      return { toNumber: () => Number(value) };
    }

    uint64() {
      return this.int64();
    }

    sint32() {
      const value = this.uint32();
      return (value >>> 1) ^ -(value & 1);
    }

    sint64() {
      const value = this.readVarint();
      const decoded = (value >> 1n) ^ (-(value & 1n));
      return { toNumber: () => Number(decoded) };
    }

    bool() {
      return this.uint32() !== 0;
    }

    string() {
      const length = this.uint32();
      const start = this.pos;
      this.pos += length;
      return new TextDecoder().decode(this.buf.slice(start, start + length));
    }

    bytes() {
      const length = this.uint32();
      const start = this.pos;
      this.pos += length;
      return this.buf.slice(start, start + length);
    }

    double() {
      const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.pos, 8);
      const value = view.getFloat64(0, true);
      this.pos += 8;
      return value;
    }

    float() {
      const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.pos, 4);
      const value = view.getFloat32(0, true);
      this.pos += 4;
      return value;
    }

    fixed32() {
      const view = new DataView(this.buf.buffer, this.buf.byteOffset + this.pos, 4);
      const value = view.getUint32(0, true);
      this.pos += 4;
      return value;
    }

    skipType(wireType) {
      if (wireType === 0) {
        this.readVarint();
        return;
      }
      if (wireType === 1) {
        this.pos += 8;
        return;
      }
      if (wireType === 2) {
        this.pos += this.uint32();
        return;
      }
      if (wireType === 3) {
        while (this.pos < this.len) {
          const tag = this.uint32();
          if ((tag & 7) === 4) break;
          this.skipType(tag & 7);
        }
        return;
      }
      if (wireType === 5) {
        this.pos += 4;
      }
    }

    readVarint() {
      let shift = 0n;
      let result = 0n;
      while (this.pos < this.len) {
        const byte = this.buf[this.pos++];
        result |= BigInt(byte & 127) << shift;
        if ((byte & 128) === 0) return result;
        shift += 7n;
      }
      return result;
    }
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  let renderResultsTimer = null;

  function scheduleRenderResults() {
    if (renderResultsTimer) return;
    renderResultsTimer = setTimeout(() => {
      renderResultsTimer = null;
      renderResults();
    }, 120);
  }

  function renderResults() {
    const list = document.getElementById("ay-price-results");
    if (!list) return;
    const products = Array.from(STATE.products.values())
      .filter((product) => product.productId && Number.isFinite(product.currentPrice))
      .filter((product) => {
        if (!STATE.filterCheaperThanLpl) return true;
        return Number.isFinite(product.lplPrice) && product.currentPrice < product.lplPrice;
      })
      .sort((left, right) => {
        const leftDelta = Number.isFinite(left.lplPrice) ? left.currentPrice - left.lplPrice : Infinity;
        const rightDelta = Number.isFinite(right.lplPrice) ? right.currentPrice - right.lplPrice : Infinity;
        return leftDelta - rightDelta;
      })
      .slice(0, 120);

    list.innerHTML = products.map(renderResultItem).join("");
  }

  function clearResults() {
    resetCollectedState();
    updateStatus("Rezultatai isvalyti. Gali krauti is naujo.");
  }

  function renderResultItem(product) {
    const delta = Number.isFinite(product.lplPrice) ? product.currentPrice - product.lplPrice : null;
    const good = Number.isFinite(delta) && delta <= 0;
    const deltaText = Number.isFinite(delta) ? `${delta > 0 ? "+" : ""}${formatPrice(delta)}` : "";
    return `
      <a href="${escapeHtml(product.url || "#")}" target="_blank" rel="noopener noreferrer">
        <span class="ay-result-name">${escapeHtml(product.name || `#${product.productId}`)}</span>
        <span class="ay-result-brand">${escapeHtml(product.brand || "")}</span>
        <span>${escapeHtml(formatPrice(product.currentPrice))}</span>
        <span class="ay-result-lpl">LPL ${escapeHtml(formatPrice(product.lplPrice))}</span>
        <span class="ay-result-delta" data-good="${String(good)}">${escapeHtml(deltaText)}</span>
      </a>
    `;
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function updateStatus(message) {
    const status = document.querySelector("#ay-price-tools .ay-status");
    if (!status) return;
    if (message) {
      status.textContent = message;
      return;
    }
    const allProducts = Array.from(STATE.products.values());
    const productsWithLpl = allProducts.filter((product) => Number.isFinite(product.lplPrice)).length;
    const cheaperThanLpl = allProducts.filter((product) => {
      return Number.isFinite(product.currentPrice) &&
        Number.isFinite(product.lplPrice) &&
        product.currentPrice < product.lplPrice;
    }).length;
    const total = Number.isFinite(STATE.stream.total) ? ` / ${STATE.stream.total}` : "";
    status.textContent = `${STATE.products.size}${total} duomenu, ${STATE.cards.length} DOM, LPL ${productsWithLpl}, < LPL ${cheaperThanLpl}`;
  }

  function updateActiveButtons() {
    const filter = document.querySelector("#ay-price-tools [data-action='filter-cheaper-than-lpl']");
    if (filter) filter.dataset.active = String(STATE.filterCheaperThanLpl);
    const stop = document.querySelector("#ay-price-tools [data-action='stop-loading']");
    if (stop) stop.disabled = !STATE.loadingAll;
  }

  function installPanel() {
    if (document.getElementById("ay-price-tools")) return;
    const panel = document.createElement("div");
    panel.id = "ay-price-tools";
    panel.innerHTML = `
      <strong>ABOUT YOU kainos</strong>
      <div class="ay-row">
        <button type="button" data-load-count="100">Užkrauti 100</button>
        <button type="button" data-load-count="200">Užkrauti 200</button>
      </div>
      <div class="ay-row">
        <button type="button" data-load-count="500">Užkrauti 500</button>
        <button type="button" data-load-count="all">Užkrauti visas</button>
      </div>
      <button type="button" data-action="stop-loading" disabled>STOP krovimą</button>
      <button type="button" data-action="filter-cheaper-than-lpl">Rodyti tik pigiau nei LPL: nuo didžiausio minuso iki 0</button>
      <button type="button" data-action="clear-results">Isvalyti rezultatus</button>
      <div class="ay-status"></div>
      <details open>
        <summary>Rezultatai</summary>
        <div id="ay-price-results"></div>
      </details>
    `;
    panel.addEventListener("click", (event) => {
      const button = event.target.closest("button");
      if (!button) return;
      const action = button.dataset.action;
      const loadCount = button.dataset.loadCount;
      if (loadCount) loadProducts(loadCount === "all" ? Infinity : Number(loadCount));
      if (action === "stop-loading") {
        STATE.stopLoading = true;
        updateStatus("Stabdoma...");
      }
      if (action === "filter-cheaper-than-lpl") {
        STATE.filterCheaperThanLpl = !STATE.filterCheaperThanLpl;
        applyFilter();
        renderResults();
        updateActiveButtons();
        updateStatus();
      }
      if (action === "clear-results") {
        clearResults();
      }
    });
    document.body.appendChild(panel);
  }

  function observeChanges() {
    let timer = null;
    const observer = new MutationObserver(() => {
      if (STATE.applyingDomChanges) return;
      clearTimeout(timer);
      timer = setTimeout(() => {
        if (STATE.applyingDomChanges) return;
        if (ensurePageContext()) return;
        parseInitialState();
        scanCards();
      }, 300);
    });
    observer.observe(document.body, { childList: true, subtree: true });
  }

  function init() {
    installStyles();
    installPanel();
    parseInitialState();
    scanCards();
    renderResults();
    observeChanges();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
