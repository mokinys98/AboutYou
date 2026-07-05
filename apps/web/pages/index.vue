<script setup lang="ts">
import { clothingCategoryTree, type CatalogFacets, type CatalogResponse } from "@catalog/shared";
const route = useRoute(); const router = useRouter(); const api = useApi();
const products = ref<CatalogResponse["items"]>([]); const facets = ref<CatalogFacets | null>(null);
const nextCursor = ref<string | null>(null); const loading = ref(true); const error = ref(""); const filtersOpen = ref(false);
let lastFacetsKey = "";
let pendingFacets: { key: string; request: Promise<CatalogFacets | null> } | null = null;
const filterKeys = ["brands", "categories", "colors", "color_shades", "sources", "sizes", "other_sizes", "materials", "patterns", "features", "styles", "product_types", "price_min", "price_max", "discount_min", "below_observed_30d", "price_comparison", "sort"];
const filters = computed<Record<string, string>>(() => Object.fromEntries(filterKeys.flatMap((key) => typeof route.query[key] === "string" && route.query[key] ? [[key, route.query[key] as string]] : [])));
const openCategory = computed(() => {
  const selected = filters.value.categories;
  return clothingCategoryTree.find((category) => category.name === selected || category.children.some((child) => child === selected))?.name ?? null;
});

function apiParams(value: Record<string, string>) {
  const query = new URLSearchParams(value);
  if (query.has("price_min")) query.set("price_min", String(Math.round(Number(query.get("price_min")) * 100)));
  if (query.has("price_max")) query.set("price_max", String(Math.round(Number(query.get("price_max")) * 100)));
  return query;
}
async function load(reset = true) {
  loading.value = true; error.value = "";
  try {
    const query = apiParams(filters.value);
    if (!reset && nextCursor.value) query.set("cursor", nextCursor.value);
    const result = await api<CatalogResponse>(`/v1/catalog?${query}`);
    products.value = reset ? result.items : [...products.value, ...result.items]; nextCursor.value = result.nextCursor;
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Katalogo užkrauti nepavyko"; }
  finally { loading.value = false; }
}
async function loadFacets(value = filters.value) {
  const query = apiParams(value);
  query.delete("sort");
  const key = query.toString();
  if (key === lastFacetsKey && facets.value) return facets.value;
  if (pendingFacets?.key === key) return pendingFacets.request;
  const request = api<CatalogFacets>(`/v1/catalog/facets?${query}`).catch(() => null);
  pendingFacets = { key, request };
  const result = await request;
  if (pendingFacets?.request === request) pendingFacets = null;
  if (result) {
    facets.value = result;
    lastFacetsKey = key;
  }
  return result;
}
async function updateFilters(value: Record<string, string>) { await router.push({ query: Object.fromEntries(Object.entries(value).filter(([, item]) => item)) }); }
async function selectCategory(category: string) {
  const next: Record<string, string> = { ...filters.value, categories: filters.value.categories === category ? "" : category };
  const nextFacets = await loadFacets(next);
  if (nextFacets) {
    const contextual: Array<[string, Array<{ value: string }>]> = [
      ["sizes", nextFacets.sizes], ["other_sizes", nextFacets.otherSizes], ["materials", nextFacets.materials],
      ["patterns", nextFacets.patterns], ["features", nextFacets.features], ["styles", nextFacets.styles], ["product_types", nextFacets.productTypes]
    ];
    for (const [key, items] of contextual) {
      if (!next[key]) continue;
      const available = new Set(items.map((item) => item.value));
      next[key] = next[key].split(",").filter((value) => available.has(value)).join(",");
    }
  }
  await updateFilters(next);
}
const categoryCount = (category: string) => facets.value?.categories.find((item) => item.value === category)?.count ?? 0;
const updateWatch = ({ id, isWatched }: { id: string; isWatched: boolean }) => {
  products.value = products.value.map((product) => product.id === id ? { ...product, isWatched } : product);
};
watch(() => route.query, () => { void Promise.all([load(true), loadFacets()]); }, { deep: true });
onMounted(() => { void Promise.all([loadFacets(), load()]); });
</script>

<template>
  <main class="catalog-page">
    <section class="catalog-hero"><p class="catalog-breadcrumbs">Vyrams <span>›</span> Drabužiai</p><div class="catalog-title-row"><div><h1>{{ filters.categories || "Drabužiai" }}</h1><p>{{ products.length }} rodomų prekių</p></div></div></section>
    <div class="catalog-toolbar"><button class="filter-trigger" @click="filtersOpen = true">Filtrai</button><span class="toolbar-spacer" /><label class="sort-control">Rūšiuoti <select :value="filters.sort || 'newest'" @change="updateFilters({ ...filters, sort: ($event.target as HTMLSelectElement).value })"><option value="newest">Naujausi</option><option value="price_asc">Kaina: mažiausia</option><option value="price_desc">Kaina: didžiausia</option><option value="discount_desc">Didžiausia nuolaida</option></select></label></div>
    <div class="catalog-layout">
      <aside class="category-nav" aria-label="Prekių kategorijos"><a class="category-sale">IŠPARDAVIMAS</a><h2>Drabužiai</h2><details v-for="category in clothingCategoryTree" :key="category.name" class="category-group" :open="openCategory === category.name"><summary :class="{ active: filters.categories === category.name }" @click.prevent="selectCategory(category.name)"><span>{{ category.name }}</span><small v-if="categoryCount(category.name)">{{ categoryCount(category.name) }}</small><i>⌄</i></summary><button v-for="child in category.children" :key="child" :class="{ active: filters.categories === child }" @click="selectCategory(child)"><span>{{ child }}</span><small v-if="categoryCount(child)">{{ categoryCount(child) }}</small></button></details><h2 class="category-root">Batai</h2><h2 class="category-root">Sportas</h2><h2 class="category-root">Aksesuarai</h2><h2 class="category-root">Streetwear</h2><h2 class="category-root">Premium</h2></aside>
      <section class="results"><CatalogFilters :model-value="filters" :facets="facets" :open="filtersOpen" @update:model-value="updateFilters" @update:open="filtersOpen = $event" /><p v-if="error" class="error-state">{{ error }}</p><div v-else-if="loading && !products.length" class="loading-grid"><div v-for="n in 8" :key="n" /></div><div v-else-if="products.length" class="product-grid"><ProductCard v-for="product in products" :key="product.id" :product="product" @watch-changed="updateWatch" /></div><div v-else class="empty-state"><h2>Produktų nerasta</h2><p>Pakeiskite filtrus arba paleiskite naują sinchronizavimą.</p></div><button v-if="nextCursor" class="load-more" :disabled="loading" @click="load(false)">{{ loading ? "Kraunama…" : "Rodyti daugiau" }}</button></section>
    </div>
  </main>
</template>
