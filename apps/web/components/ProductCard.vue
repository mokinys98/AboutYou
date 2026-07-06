<script setup lang="ts">
import type { CatalogItem } from "@catalog/shared";
const props = defineProps<{ product: CatalogItem }>();
const emit = defineEmits<{ watchChanged: [value: { id: string; isWatched: boolean }] }>();
const api = useApi();
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
</script>

<template>
  <article class="product-card">
    <NuxtLink :to="`/products/${product.id}`" class="product-image-wrap" target="_blank" rel="noopener noreferrer">
      <img v-if="product.imageUrls[0]" :src="product.imageUrls[0]" :alt="product.name" class="product-image" loading="lazy">
      <div v-else class="image-placeholder">Nuotraukos nėra</div>
      <span v-if="discount" class="discount-badge">-{{ discount }}%</span>
    </NuxtLink>
    <button class="watch-button" :class="{ active: watched }" :disabled="watchPending" :aria-label="watched ? 'Pašalinti iš stebimų prekių' : 'Stebėti prekę'" :aria-pressed="watched" @click.stop.prevent="toggleWatch">{{ watched ? "♥" : "♡" }}</button>
    <div class="product-copy">
      <p class="product-brand">{{ product.brand || product.source }}</p>
      <NuxtLink :to="`/products/${product.id}`" class="product-name" target="_blank" rel="noopener noreferrer">{{ product.name }}</NuxtLink>
      <p class="catalog-price">{{ format(product.currentPrice) }}</p>
      <p v-if="product.originalPrice !== null" class="price-note">Pradinė kaina: {{ format(product.originalPrice) }}</p>
      <p v-if="lowestPrice !== null" class="price-note">{{ lowestLabel }}: {{ format(lowestPrice) }}</p>
    </div>
  </article>
</template>
