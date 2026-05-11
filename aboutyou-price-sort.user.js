// ==UserScript==
// @name         ABOUT YOU price sorter
// @namespace    local.aboutyou.price-sort
// @version      0.1.0
// @description  Sort ABOUT YOU product grids by current price or lowest prior price, highlight products that are more expensive than their last lowest price, and export prices to CSV.
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

  const STREAM_SERVICE = "BrandHubPageService/GetStream";
  const PRODUCT_PATH_RE = /\/p\/[^?#]+-(\d+)(?:[?#]|$)/;
  const STATE = {
    products: new Map(),
    cards: [],
    grid: null,
    filterOverLpl: false,
    lastSort: null,
    loadingAll: false,
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
        const key = String(entry?.[0] || "");
        const payload = entry?.[1];
        if (!key.includes(STREAM_SERVICE)) continue;
        const items = payload?.data?.items || [];
        for (const item of items) {
          const tile = item?.type?.productSection?.productTile;
          if (tile) upsertProduct(productFromTile(tile));
        }
      }
    }
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

    const text = card.textContent || "";
    const prices = Array.from(text.matchAll(/(\d{1,4}(?:[ .]\d{3})*|\d+)(?:[,.](\d{1,2}))?\s*€/g))
      .map((match) => parsePriceText(match[0]))
      .filter((price) => price !== null);
    const lplMatch = text.match(/Paskutinė\s+mažiausia\s+kaina\D+(\d{1,4}(?:[ .]\d{3})*|\d+)(?:[,.](\d{1,2}))?\s*€/i);
    const originalMatch = text.match(/Pradinė\s+kaina\D+(\d{1,4}(?:[ .]\d{3})*|\d+)(?:[,.](\d{1,2}))?\s*€/i);

    return {
      productId: id,
      url: productUrl(href),
      currentPrice: prices[0] ?? null,
      originalPrice: originalMatch ? parsePriceText(originalMatch[0]) : null,
      lplPrice: lplMatch ? parsePriceText(lplMatch[0]) : null,
      name: guessName(card),
    };
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

      const over = Number.isFinite(product.currentPrice) && product.currentPrice > product.lplPrice;
      const diff = over ? ` / dabar +${formatPrice(product.currentPrice - product.lplPrice)}` : "";
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

  function sortCards(kind) {
    scanCards();
    const sorted = [...STATE.cards].sort((left, right) => {
      const a = productForCard(left);
      const b = productForCard(right);
      const av = kind === "lpl" ? a.lplPrice : a.currentPrice;
      const bv = kind === "lpl" ? b.lplPrice : b.currentPrice;
      const an = Number.isFinite(av);
      const bn = Number.isFinite(bv);
      if (an && bn) return av - bv;
      if (an) return -1;
      if (bn) return 1;
      return left.productId - right.productId;
    });

    if (STATE.grid) {
      STATE.applyingDomChanges = true;
      for (const card of sorted) STATE.grid.appendChild(card.element);
      STATE.cards = sorted;
      STATE.lastSort = kind;
      updateActiveButtons();
      applyFilter();
      updateStatus();
      setTimeout(() => {
        STATE.applyingDomChanges = false;
      }, 0);
    }
  }

  function applyFilter() {
    for (const card of STATE.cards) {
      const product = productForCard(card);
      const over = Number.isFinite(product.currentPrice) &&
        Number.isFinite(product.lplPrice) &&
        product.currentPrice > product.lplPrice;
      card.element.classList.toggle("ay-hidden-by-lpl-filter", STATE.filterOverLpl && !over);
    }
  }

  async function loadAllProducts() {
    if (STATE.loadingAll) return;
    STATE.loadingAll = true;
    updateStatus("Kraunama...");

    let stableRounds = 0;
    let previousCount = 0;
    for (let round = 0; round < 60 && stableRounds < 5; round += 1) {
      scanCards();
      const count = STATE.cards.length;
      stableRounds = count === previousCount ? stableRounds + 1 : 0;
      previousCount = count;
      window.scrollTo(0, document.documentElement.scrollHeight);
      await sleep(850);
    }

    window.scrollTo({ top: 0, behavior: "smooth" });
    STATE.loadingAll = false;
    scanCards();
    if (STATE.lastSort) sortCards(STATE.lastSort);
    updateStatus();
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  function exportCsv() {
    scanCards();
    const rows = [["productId", "name", "currentPrice", "originalPrice", "lastLowestPrice", "differenceCurrentMinusLpl", "url"]];
    for (const card of STATE.cards) {
      const product = productForCard(card);
      rows.push([
        product.productId || card.productId,
        product.name || "",
        formatPrice(product.currentPrice),
        formatPrice(product.originalPrice),
        formatPrice(product.lplPrice),
        Number.isFinite(product.currentPrice) && Number.isFinite(product.lplPrice)
          ? formatPrice(product.currentPrice - product.lplPrice)
          : "",
        product.url || "",
      ]);
    }

    const csv = rows.map((row) => row.map(csvCell).join(",")).join("\r\n");
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `aboutyou-prices-${new Date().toISOString().slice(0, 10)}.csv`;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  }

  function csvCell(value) {
    const text = String(value ?? "");
    return `"${text.replace(/"/g, '""')}"`;
  }

  function updateStatus(message) {
    const status = document.querySelector("#ay-price-tools .ay-status");
    if (!status) return;
    if (message) {
      status.textContent = message;
      return;
    }
    const productsWithLpl = STATE.cards.filter((card) => Number.isFinite(productForCard(card).lplPrice)).length;
    const overLpl = STATE.cards.filter((card) => {
      const product = productForCard(card);
      return Number.isFinite(product.currentPrice) &&
        Number.isFinite(product.lplPrice) &&
        product.currentPrice > product.lplPrice;
    }).length;
    status.textContent = `${STATE.cards.length} prekių, LPL turi ${productsWithLpl}, brangiau už LPL ${overLpl}`;
  }

  function updateActiveButtons() {
    for (const button of document.querySelectorAll("#ay-price-tools [data-sort]")) {
      button.dataset.active = String(button.dataset.sort === STATE.lastSort);
    }
    const filter = document.querySelector("#ay-price-tools [data-action='filter-over-lpl']");
    if (filter) filter.dataset.active = String(STATE.filterOverLpl);
  }

  function installPanel() {
    if (document.getElementById("ay-price-tools")) return;
    const panel = document.createElement("div");
    panel.id = "ay-price-tools";
    panel.innerHTML = `
      <strong>ABOUT YOU kainos</strong>
      <button type="button" data-action="load-all">Užkrauti visas prekes</button>
      <div class="ay-row">
        <button type="button" data-sort="current">Rikiuoti pagal dabartinę kainą</button>
        <button type="button" data-sort="lpl">Rikiuoti pagal paskutinę mažiausią kainą</button>
      </div>
      <button type="button" data-action="filter-over-lpl">Rodyti tik kai dabartinė > paskutinė mažiausia</button>
      <button type="button" data-action="export-csv">Eksportuoti CSV</button>
      <div class="ay-status"></div>
    `;
    panel.addEventListener("click", (event) => {
      const button = event.target.closest("button");
      if (!button) return;
      const sort = button.dataset.sort;
      const action = button.dataset.action;
      if (sort) sortCards(sort);
      if (action === "load-all") loadAllProducts();
      if (action === "filter-over-lpl") {
        STATE.filterOverLpl = !STATE.filterOverLpl;
        applyFilter();
        updateActiveButtons();
      }
      if (action === "export-csv") exportCsv();
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
        if (STATE.lastSort) sortCards(STATE.lastSort);
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
