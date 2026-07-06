<script setup lang="ts">
import type { CatalogItem } from "@catalog/shared";
type Detail = CatalogItem & {
  history: Array<{ observed_date: string; min_price: number; max_price: number; last_price: number; source_lpl_30: number | null }>;
  priceChanges: Array<{ observed_at: string; price: number; original_price: number | null; source_lpl_30: number | null }>;
};
const route = useRoute(); const api = useApi(); const product = ref<Detail | null>(null); const error = ref(""); const watchError = ref(""); const watchPending = ref(false);
const format = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("lt-LT", { style: "currency", currency: product.value?.currency || "EUR" }).format(value / 100);
const formatObservedAt = (value: string) => new Intl.DateTimeFormat("lt-LT", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
async function toggleWatch() {
  if (!product.value || watchPending.value) return;
  watchPending.value = true;
  watchError.value = "";
  const next = !product.value.isWatched;
  try {
    await api(`/v1/watchlist/${product.value.id}`, { method: next ? "PUT" : "DELETE" });
    product.value.isWatched = next;
  } catch (cause) {
    watchError.value = cause instanceof Error ? cause.message : "Stebėjimo būsenos pakeisti nepavyko";
  } finally { watchPending.value = false; }
}
onMounted(async () => { try { product.value = await api<Detail>(`/v1/products/${route.params.id}`); } catch (cause) { error.value = cause instanceof Error ? cause.message : "Produkto užkrauti nepavyko"; } });
</script>

<template><main class="detail-page"><NuxtLink to="/" class="back">← Grįžti į katalogą</NuxtLink><p v-if="error" class="error-state">{{ error }}</p><section v-else-if="product" class="detail-grid"><div class="detail-image"><img v-if="product.imageUrls[0]" :src="product.imageUrls[0]" :alt="product.name"></div><div><div class="detail-heading"><div><p class="eyebrow">{{ product.brand }}</p><h1>{{ product.name }}</h1></div><button class="detail-watch" :class="{ active: product.isWatched }" :disabled="watchPending" :aria-pressed="product.isWatched" @click="toggleWatch">{{ product.isWatched ? "♥ Stebima" : "♡ Stebėti" }}</button></div><p v-if="watchError" class="error">{{ watchError }}</p><p class="detail-price">{{ format(product.currentPrice) }}</p><p v-if="product.originalPrice"><s>{{ format(product.originalPrice) }}</s></p><dl><div><dt>30 d. mūsų minimumas</dt><dd>{{ format(product.observedMin30d) }}</dd></div><div><dt>Šaltinio LPL</dt><dd>{{ format(product.sourceLpl30) }}</dd></div><div><dt>Spalva</dt><dd>{{ product.colorOriginal || product.colorShade }}</dd></div></dl><a :href="product.productUrl" target="_blank" rel="noopener noreferrer" class="primary external">Atidaryti ABOUT YOU ↗</a></div></section><section v-if="product?.priceChanges.length" class="history"><h2>Kainos pokyčiai</h2><div class="history-list"><div v-for="change in product.priceChanges" :key="change.observed_at"><time>{{ formatObservedAt(change.observed_at) }}</time><strong>{{ format(change.price) }}</strong><span v-if="change.original_price !== null">pradinė {{ format(change.original_price) }}</span></div></div></section></main></template>
