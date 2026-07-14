<script setup lang="ts">
import type { CatalogResponse } from "@catalog/shared";
const api = useApi();
const products = ref<CatalogResponse["items"]>([]);
const nextCursor = ref<string | null>(null);
const loading = ref(true);
const error = ref("");
async function load(reset = true) {
  loading.value = true; error.value = "";
  try {
    const query = new URLSearchParams();
    if (!reset && nextCursor.value) query.set("cursor", nextCursor.value);
    const result = await api<CatalogResponse>(`/v1/watchlist?${query}`);
    products.value = reset ? result.items : [...products.value, ...result.items];
    nextCursor.value = result.nextCursor;
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Stebimų prekių užkrauti nepavyko"; }
  finally { loading.value = false; }
}
const removeUnwatched = ({ id, isWatched }: { id: string; isWatched: boolean }) => {
  if (!isWatched) products.value = products.value.filter((product) => product.id !== id);
};
onMounted(() => { void load(); });
</script>

<template><main class="catalog-page watchlist-page"><section class="catalog-hero"><p class="eyebrow">ASMENINIS SĄRAŠAS</p><div class="catalog-title-row"><div><h1>Stebimos prekės</h1><p>{{ products.length }} prekių</p></div></div></section><p v-if="error" class="error-state">{{ error }}</p><div v-else-if="loading && !products.length" class="loading-grid"><div v-for="n in 8" :key="n" /></div><div v-else-if="products.length" class="product-grid"><ProductCard v-for="product in products" :key="product.id" :product="product" show-alert @watch-changed="removeUnwatched" /></div><div v-else class="empty-state"><h2>Stebimų prekių nėra</h2><p>Kataloge paspauskite širdelę prie norimos prekės.</p><NuxtLink to="/" class="primary empty-action">Atidaryti katalogą</NuxtLink></div><button v-if="nextCursor" class="load-more" :disabled="loading" @click="load(false)">{{ loading ? "Kraunama…" : "Rodyti daugiau" }}</button></main></template>
