<script setup lang="ts">
import { buildCategoryTree, type CatalogFacets, type CatalogResponse } from "@catalog/shared";
definePageMeta({ alias: ["/naujienos"] });
const route = useRoute(); const router = useRouter(); const api = useApi();
const isNews = computed(() => route.path === "/naujienos");
const products = ref<CatalogResponse["items"]>([]); const facets = ref<CatalogFacets | null>(null);
const nextCursor = ref<string | null>(null); const loading = ref(true); const error = ref(""); const filtersOpen = ref(false);
let lastFacetsKey = "";
let pendingFacets: { key: string; request: Promise<CatalogFacets | null> } | null = null;
const filterKeys = ["brands", "categories", "category", "colors", "color_shades", "sources", "sizes", "other_sizes", "materials", "patterns", "features", "styles", "product_types", "price_min", "price_max", "discount_min", "below_observed_30d", "price_comparison", "sort"];
const filters = computed<Record<string, string>>(() => Object.fromEntries(filterKeys.flatMap((key) => typeof route.query[key] === "string" && route.query[key] ? [[key, route.query[key] as string]] : [])));
const categoryTree = computed(() => buildCategoryTree(facets.value?.categories ?? []));
const selectedCategory = computed(() => facets.value?.categories.find((category) => category.path === filters.value.category) ?? null);
const categoryTrail = computed(() => {
  const items = facets.value?.categories ?? [];
  const byId = new Map(items.map((item) => [item.id, item]));
  const trail = [] as typeof items;
  let current = selectedCategory.value;
  while (current) {
    trail.unshift(current);
    current = current.parentId ? byId.get(current.parentId) ?? null : null;
  }
  return trail;
});
const catalogTitle = computed(() => selectedCategory.value?.name || filters.value.categories || "Visos prekės");

function apiParams(value: Record<string, string>) {
  const query = new URLSearchParams(value);
  if (isNews.value) {
    query.set("new_only", "true");
    if (!query.has("sort") || query.get("sort") === "newest") query.set("sort", "first_seen");
  }
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
  const next: Record<string, string> = { ...filters.value, category: filters.value.category === category ? "" : category };
  delete next.categories;
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
const updateWatch = ({ id, isWatched }: { id: string; isWatched: boolean }) => {
  products.value = products.value.map((product) => product.id === id ? { ...product, isWatched } : product);
};
watch(() => route.query, () => { void Promise.all([load(true), loadFacets()]); }, { deep: true });
onMounted(() => { void Promise.all([loadFacets(), load()]); });
</script>

<template>
  <main class="catalog-page">
    <section class="catalog-hero"><p class="catalog-breadcrumbs">Vyrams <template v-if="isNews"><span>›</span> Naujienos</template><template v-else v-for="category in categoryTrail" :key="category.id"><span>›</span> {{ category.name }}</template></p><div class="catalog-title-row"><div><h1>{{ isNews ? "Naujienos" : catalogTitle }}</h1><p>{{ isNews ? "Per paskutines 30 dienų pirmą kartą aptiktos prekės" : `${products.length} rodomų prekių` }}</p></div></div></section>
    <div class="catalog-toolbar"><button class="filter-trigger" @click="filtersOpen = true">Filtrai</button><span class="toolbar-spacer" /><label class="sort-control">Rūšiuoti <select :value="filters.sort || 'newest'" @change="updateFilters({ ...filters, sort: ($event.target as HTMLSelectElement).value })"><option value="newest">Naujausi</option><option value="price_asc">Kaina: mažiausia</option><option value="price_desc">Kaina: didžiausia</option><option value="discount_desc">Didžiausia nuolaida</option></select></label></div>
    <div class="catalog-layout">
      <aside class="category-nav" aria-label="Prekių kategorijos"><NuxtLink to="/naujienos" class="category-news" :class="{ active: isNews }">NAUJIENOS</NuxtLink><a class="category-sale">IŠPARDAVIMAS</a><h2>Kategorijos</h2><CategoryTreeItem v-for="category in categoryTree" :key="category.id" :node="category" :selected-path="filters.category" @select="selectCategory" /></aside>
      <section class="results"><CatalogFilters :model-value="filters" :facets="facets" :open="filtersOpen" @update:model-value="updateFilters" @update:open="filtersOpen = $event" /><p v-if="error" class="error-state">{{ error }}</p><div v-else-if="loading && !products.length" class="loading-grid"><div v-for="n in 8" :key="n" /></div><div v-else-if="products.length" class="product-grid"><ProductCard v-for="product in products" :key="product.id" :product="product" @watch-changed="updateWatch" /></div><div v-else class="empty-state"><h2>Produktų nerasta</h2><p>Pakeiskite filtrus arba paleiskite naują sinchronizavimą.</p></div><button v-if="nextCursor" class="load-more" :disabled="loading" @click="load(false)">{{ loading ? "Kraunama…" : "Rodyti daugiau" }}</button></section>
    </div>
  </main>
</template>
