<script setup lang="ts">
import type { CatalogItem } from "@catalog/shared";
const props = defineProps<{ product: CatalogItem }>();
const format = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("lt-LT", { style: "currency", currency: props.product.currency }).format(value / 100);
const discount = computed(() => props.product.originalPrice ? Math.max(0, Math.round((props.product.originalPrice - props.product.currentPrice) * 100 / props.product.originalPrice)) : 0);
</script>

<template>
  <article class="product-card">
    <NuxtLink :to="`/products/${product.id}`" class="product-image-wrap">
      <img v-if="product.imageUrls[0]" :src="product.imageUrls[0]" :alt="product.name" class="product-image" loading="lazy">
      <div v-else class="image-placeholder">Nuotraukos nėra</div>
      <span v-if="discount" class="discount-badge">-{{ discount }}%</span>
    </NuxtLink>
    <div class="product-copy">
      <p class="product-brand">{{ product.brand || product.source }}</p>
      <NuxtLink :to="`/products/${product.id}`" class="product-name">{{ product.name }}</NuxtLink>
      <div class="prices"><strong>{{ format(product.currentPrice) }}</strong><s v-if="product.originalPrice">{{ format(product.originalPrice) }}</s></div>
      <p class="price-note">30 d. mūsų min.: {{ format(product.observedMin30d) }}</p>
      <p class="price-note">Šaltinio LPL: {{ format(product.sourceLpl30) }}</p>
    </div>
  </article>
</template>

