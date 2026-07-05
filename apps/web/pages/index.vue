<script setup lang="ts">
import type { CatalogFacets, CatalogResponse } from "@catalog/shared";
const route = useRoute(); const router = useRouter(); const api = useApi();
const products = ref<CatalogResponse["items"]>([]); const facets = ref<CatalogFacets | null>(null);
const nextCursor = ref<string | null>(null); const loading = ref(true); const error = ref(""); const filtersOpen = ref(false);
const filterKeys = ["brands", "categories", "colors", "sources", "price_min", "price_max", "discount_min", "below_observed_30d", "sort"];
const filters = computed<Record<string, string>>(() => Object.fromEntries(filterKeys.flatMap((key) => typeof route.query[key] === "string" && route.query[key] ? [[key, route.query[key] as string]] : [])));

async function load(reset = true) {
  loading.value = true; error.value = "";
  try {
    const query = new URLSearchParams(filters.value);
    if (!reset && nextCursor.value) query.set("cursor", nextCursor.value);
    if (query.has("price_min")) query.set("price_min", String(Math.round(Number(query.get("price_min")) * 100)));
    if (query.has("price_max")) query.set("price_max", String(Math.round(Number(query.get("price_max")) * 100)));
    const result = await api<CatalogResponse>(`/v1/catalog?${query}`);
    products.value = reset ? result.items : [...products.value, ...result.items]; nextCursor.value = result.nextCursor;
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Katalogo užkrauti nepavyko"; }
  finally { loading.value = false; }
}
async function updateFilters(value: Record<string, string>) { await router.push({ query: Object.fromEntries(Object.entries(value).filter(([, item]) => item)) }); }
watch(() => route.query, () => load(true), { deep: true });
onMounted(async () => { facets.value = await api<CatalogFacets>("/v1/catalog/facets").catch(() => null); await load(); });
</script>

<template>
  <main class="catalog-page">
    <section class="catalog-hero"><p class="eyebrow">ATRINKTOS GRUPĖS · ATNAUJINAMA 4× PER DIENĄ</p><h1>Privatus mados kainų katalogas</h1><p>Filtruokite realiai stebimas kainas ir palyginkite jas su 30 dienų minimumu.</p></section>
    <div class="catalog-toolbar"><button class="filter-trigger" @click="filtersOpen = true">Filtrai</button><span>{{ products.length }} produktų</span><select :value="filters.sort || 'newest'" @change="updateFilters({ ...filters, sort: ($event.target as HTMLSelectElement).value })"><option value="newest">Naujausi</option><option value="price_asc">Kaina: mažiausia</option><option value="price_desc">Kaina: didžiausia</option><option value="discount_desc">Didžiausia nuolaida</option></select></div>
    <div class="catalog-layout">
      <CatalogFilters :model-value="filters" :facets="facets" :open="filtersOpen" @update:model-value="updateFilters" @update:open="filtersOpen = $event" />
      <section class="results"><p v-if="error" class="error-state">{{ error }}</p><div v-else-if="loading && !products.length" class="loading-grid"><div v-for="n in 8" :key="n" /></div><div v-else-if="products.length" class="product-grid"><ProductCard v-for="product in products" :key="product.id" :product="product" /></div><div v-else class="empty-state"><h2>Produktų nerasta</h2><p>Pakeiskite filtrus arba pridėkite sinchronizavimo grupę.</p></div><button v-if="nextCursor" class="load-more" :disabled="loading" @click="load(false)">{{ loading ? "Kraunama…" : "Rodyti daugiau" }}</button></section>
    </div>
  </main>
</template>

