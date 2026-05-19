// ==UserScript==
// @name         ABOUT YOU price sorter
// @namespace    local.aboutyou.price-sort
// @version      0.1.0
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

  console.warn("[ABOUT YOU price sorter] userscript loaded", location.href);
  window.__ABOUTYOU_PRICE_SORTER_LOADED__ = true;

  const PRODUCT_PATH_RE = /\/p\/[^?#]+-(\d+)(?:[?#]|$)/;
  const STATE = {
    products: new Map(),
    cards: [],
    grid: null,
    filterCheaperThanLpl: false,
    loadingAll: false,
    stopLoading: false,
    applyingDomChanges: false,
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

  function upsertProduct(product) {
    if (!product || !product.productId) return;
    const existing = STATE.products.get(product.productId) || {};
    STATE.products.set(product.productId, { ...existing, ...compact(product) });
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
    const lplPrice =
      parsePriceText(priceV2.lpl30d?.value?.text) ??
      parsePriceText(tile.price?.lpl30);

    return {
      productId: tile.productId,
      name: tile.productTracker?.productName || "",
      url: productUrl(tile.link?.url || tile.productTracker?.linkTarget),
      currentPrice,
      originalPrice,
      lplPrice,
      brand: tile.brandName || tile.brandTracker?.name || "",
    };
  }

  function parseInitialState() {
    for (const script of document.querySelectorAll('script[data-tadarida-initial-state="true"]')) {
      let entries;
      try {
        entries = JSON.parse(script.textContent || "[]");
      } catch (_) {
        continue;
      }

      if (!Array.isArray(entries)) continue;
      for (const entry of entries) {
        const payload = entry?.[1];
        collectProductTiles(payload, (tile) => upsertProduct(productFromTile(tile)));
      }
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

    return {
      productId: id,
      url: productUrl(href),
      currentPrice: resolveDomCurrentPrice(prices, originalMatch, lplMatch),
      originalPrice: originalMatch ? parsePriceText(originalMatch[0]) : null,
      lplPrice: lplMatch ? parsePriceText(lplMatch[0]) : null,
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
      if (cleaned && !cleaned.includes("€") && cleaned.length > 3) return cleaned;
    }
    return "";
  }

  function scanCards() {
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
      const over = hasCurrentPrice && product.currentPrice >= product.lplPrice;
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
        product.currentPrice <= product.lplPrice;
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

  async function loadProducts(targetCount) {
    if (STATE.loadingAll) return;
    STATE.loadingAll = true;
    STATE.stopLoading = false;
    const restoreFilterAfterLoad = STATE.filterCheaperThanLpl;
    STATE.filterCheaperThanLpl = false;
    applyFilter();
    updateActiveButtons();
    const targetLabel = Number.isFinite(targetCount) ? `${targetCount}` : "visos";
    updateStatus(`Kraunama iki ${targetLabel}...`);

    let stableRounds = 0;
    let previousCount = 0;
    const maxRounds = Number.isFinite(targetCount) ? 40 : 120;
    for (let round = 0; round < maxRounds && stableRounds < 5; round += 1) {
      if (STATE.stopLoading) break;
      scanCards();
      const count = STATE.cards.length;
      if (Number.isFinite(targetCount) && count >= targetCount) break;
      stableRounds = count === previousCount ? stableRounds + 1 : 0;
      previousCount = count;
      window.scrollTo(0, document.documentElement.scrollHeight);
      await sleep(850);
    }

    window.scrollTo({ top: 0, behavior: "smooth" });
    const wasStopped = STATE.stopLoading;
    STATE.loadingAll = false;
    STATE.stopLoading = false;
    STATE.filterCheaperThanLpl = restoreFilterAfterLoad;
    updateActiveButtons();
    scanCards();
    applyFilter();
    updateStatus(wasStopped ? "Krovimas sustabdytas." : undefined);
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  function updateStatus(message) {
    const status = document.querySelector("#ay-price-tools .ay-status");
    if (!status) return;
    if (message) {
      status.textContent = message;
      return;
    }
    const productsWithLpl = STATE.cards.filter((card) => Number.isFinite(productForCard(card).lplPrice)).length;
    const cheaperThanLpl = STATE.cards.filter((card) => {
      const product = productForCard(card);
      return Number.isFinite(product.currentPrice) &&
        Number.isFinite(product.lplPrice) &&
        product.currentPrice <= product.lplPrice;
    }).length;
    status.textContent = `${STATE.cards.length} prekių, LPL turi ${productsWithLpl}, pigiau arba lygu LPL ${cheaperThanLpl}`;
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
      <button type="button" data-action="filter-cheaper-than-lpl">Rodyti pigiau arba lygu LPL: nuo didžiausio minuso iki 0</button>
      <div class="ay-status"></div>
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
        updateActiveButtons();
        updateStatus();
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
    observeChanges();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init, { once: true });
  } else {
    init();
  }
})();
