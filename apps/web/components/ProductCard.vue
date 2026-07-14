<script setup lang="ts">
import type { CatalogItem } from "@catalog/shared";
const props = withDefaults(defineProps<{ product: CatalogItem; showAlert?: boolean }>(), {
  showAlert: false
});
const emit = defineEmits<{ watchChanged: [value: { id: string; isWatched: boolean }] }>();
const api = useApi();
const { enabled: debugEnabled } = useProductDebug();
const watched = ref(props.product.isWatched);
const watchPending = ref(false);
watch(() => props.product.isWatched, (value) => { watched.value = value; });
const format = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("lt-LT", { style: "currency", currency: props.product.currency }).format(value / 100);
const discount = computed(() => Math.round(props.product.discountPct));
const lowestPrice = computed(() => props.product.sourceLpl30 ?? props.product.observedMin30d);
const lowestLabel = computed(() => props.product.sourceLpl30 !== null ? "Paskutinė mažiausia kaina" : "Mūsų 30 d. mažiausia kaina");
async function toggleWatch() {
  if (watchPending.value) return;
  watchPending.value = true;
  const next = !watched.value;
  watched.value = next;
  try {
    await api(`/v1/watchlist/${props.product.id}`, { method: next ? "PUT" : "DELETE" });
    emit("watchChanged", { id: props.product.id, isWatched: next });
  } catch {
    watched.value = !next;
  } finally {
    watchPending.value = false;
  }
}
function onAlertSaved(value: { id: string; isWatched: true }) {
  watched.value = true;
  emit("watchChanged", value);
}
</script>

<template>
  <article class="product-card">
    <a :href="product.productUrl" class="product-card-target" target="_blank" rel="noopener noreferrer" :aria-label="`Atidaryti ${product.name} ABOUT YOU puslapyje`" />
    <div class="product-image-wrap">
      <img v-if="product.imageUrls[0]" :src="product.imageUrls[0]" :alt="product.name" class="product-image" loading="lazy">
      <div v-else class="image-placeholder">Nuotraukos nėra</div>
      <BrandTierRibbon :tier="product.brandTier" />
      <span v-if="discount" class="discount-badge">-{{ discount }}%</span>
    </div>
    <button class="watch-button" :class="{ active: watched }" :disabled="watchPending" :aria-label="watched ? 'Pašalinti iš stebimų prekių' : 'Stebėti prekę'" :aria-pressed="watched" @click.stop.prevent="toggleWatch">{{ watched ? "♥" : "♡" }}</button>
    <ProductAlertDialog v-if="showAlert" :product="product" @saved="onAlertSaved" />
    <button class="watch-button product-page-button" type="button" aria-label="Produkto puslapis" :aria-pressed="false" @click.stop.prevent="navigateTo(`/products/${product.id}`)">
      <svg aria-hidden="true" viewBox="0 0 24 24"><path d="M6 8h12l1 12H5L6 8Zm3 2V7a3 3 0 0 1 6 0v3" /></svg>
    </button>
    <button v-if="debugEnabled" class="watch-button product-debug-button" type="button" aria-label="Produkto debug informacija" @click.stop.prevent="navigateTo(`/products/${product.id}/debug`)">&lt;/&gt;</button>
    <div class="product-copy">
      <p class="product-brand">{{ product.brand || product.source }}</p>
      <span class="product-name">{{ product.name }}</span>
      <p class="catalog-price">{{ format(product.currentPrice) }}</p>
      <p v-if="product.originalPrice !== null" class="price-note">Pradinė kaina: {{ format(product.originalPrice) }}</p>
      <p v-if="lowestPrice !== null" class="price-note">{{ lowestLabel }}: {{ format(lowestPrice) }}</p>
    </div>
  </article>
</template>
