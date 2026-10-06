<script setup lang="ts">
import { catalogSortOptions } from "~/utils/catalogSort";

import { buildCategoryTree, clothingCategoryTree, type CatalogCategoryFacet, type CatalogFacets, type CatalogResponse } from "@catalog/shared";
definePageMeta({ alias: ["/naujienos"] });
const route = useRoute(); const router = useRouter(); const api = useApi();
const isNews = computed(() => route.path === "/naujienos");
const products = ref<CatalogResponse["items"]>([]); const facets = ref<CatalogFacets | null>(null);
const nextCursor = ref<string | null>(null); const loading = ref(true); const error = ref(""); const filtersOpen = ref(false);
const facetsLoading = ref(false); const facetsError = ref("");
const totalCount = ref(0);
const gridColumns = ref<3 | 4>(3);
const expandedRootPath = ref<string | null>(null);
let lastFacetsKey = "";
const pendingFacets = new Map<string, { promise: Promise<CatalogFacets>; controller: AbortController }>();
let facetsRequestId = 0;
let productRequestId = 0;
let productAbortController: AbortController | null = null;
const catalogRequestTimeoutMs = 15_000;
// The database caches each exact filter context. Keep the browser cache short so
// a catalog refresh or a classification override cannot remain stale all day.
const facetsCacheTtlMs = 5 * 60 * 1000;
const facetsCachePrefix = "catalog-facets:v4:";
const filterKeys = ["brands", "brand_tiers", "categories", "category", "colors", "color_shades", "sources", "sizes", "other_sizes", "materials", "patterns", "features", "styles", "product_types", "premium", "exclude_basics", "exclude_accessories", "price_min", "price_max", "discount_min", "lpl_proximity_pct", "below_observed_30d", "price_comparison", "catalog_version", "sort"];
const filters = computed<Record<string, string>>(() => Object.fromEntries(filterKeys.flatMap((key) => typeof route.query[key] === "string" && route.query[key] ? [[key, route.query[key] as string]] : [])));
const fallbackCategoryFacets = createFallbackCategoryFacets();
const categoryFacets = computed(() => facets.value?.categories.length ? facets.value.categories : fallbackCategoryFacets);
const categoryTree = computed(() => buildCategoryTree(categoryFacets.value));
const selectedCategory = computed(() => categoryFacets.value.find((category) => category.path === filters.value.category) ?? null);
const categoryTrail = computed(() => {
  const items = categoryFacets.value;
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
const formattedCount = computed(() => new Intl.NumberFormat("lt-LT").format(totalCount.value));
watch([categoryTree, () => filters.value.category], ([roots, selectedPath]) => {
  const selectedRoot = selectedPath
    ? roots.find((root) => selectedPath === root.path || selectedPath.startsWith(`${root.path}>`))
    : null;
  if (selectedRoot) expandedRootPath.value = selectedRoot.path;
  else if (!expandedRootPath.value || !roots.some((root) => root.path === expandedRootPath.value)) expandedRootPath.value = roots[0]?.path ?? null;
}, { immediate: true });

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
function createFallbackCategoryFacets(): CatalogCategoryFacet[] {
  const items: CatalogCategoryFacet[] = [];
  const add = (id: string, parentId: string | null, name: string, level: number, path: string) => {
    items.push({ id, parentId, name, level, path, count: 0 });
  };
  add("fallback-drabuziai", null, "Drabužiai", 2, "vyrams>drabužiai");
  clothingCategoryTree.forEach((category, index) => {
    add(`fallback-drabuziai-${index}`, "fallback-drabuziai", category.name, 3, `vyrams>drabužiai>${category.name.toLocaleLowerCase("lt")}`);
  });
  const roots: Array<[string, string, string]> = [
    ["fallback-batai", "Batai", "vyrams>batai"],
    ["fallback-sportas", "Sportas", "vyrams>sportas"],
    ["fallback-aksesuarai", "Aksesuarai", "vyrams>aksesuarai"],
  ];
  roots.forEach(([id, name, path]) => add(id, null, name, 2, path));
  return items;
}
function facetsCacheKey(key: string) {
  return `${facetsCachePrefix}${key || "root"}`;
}
function restoreCachedFacets(key: string) {
  if (!import.meta.client) return false;
  try {
    const cached = localStorage.getItem(facetsCacheKey(key));
    if (!cached) return false;
    const parsed = JSON.parse(cached) as { cachedAt?: number; value?: CatalogFacets };
    if (!parsed.cachedAt || !parsed.value || Date.now() - parsed.cachedAt > facetsCacheTtlMs) return false;
    facets.value = parsed.value;
    lastFacetsKey = key;
    return true;
  } catch {
    return false;
  }
}
function storeCachedFacets(key: string, value: CatalogFacets) {
  if (!import.meta.client) return;
  try {
    localStorage.setItem(facetsCacheKey(key), JSON.stringify({ cachedAt: Date.now(), value }));
  } catch {
    // Ignore storage quota/privacy mode failures; the API response is still rendered.
  }
}
function clearStoredFacetCache() {
  if (!import.meta.client) return;
  for (const key of Object.keys(localStorage)) if (key.startsWith(facetsCachePrefix)) localStorage.removeItem(key);
  for (const [key, pending] of pendingFacets) {
    pending.controller.abort();
    pendingFacets.delete(key);
  }
  lastFacetsKey = "";
}
function handleFacetCacheInvalidation() {
  if (!import.meta.client || !localStorage.getItem("catalog-facets:invalidate")) return;
  localStorage.removeItem("catalog-facets:invalidate");
  clearStoredFacetCache();
  void loadFacets(filters.value, { force: true });
}
async function load(reset = true) {
  const requestId = ++productRequestId;
  productAbortController?.abort();
  const controller = new AbortController();
  productAbortController = controller;
  loading.value = true; error.value = "";
  try {
    const query = apiParams(filters.value);
    if (!reset && nextCursor.value) query.set("cursor", nextCursor.value);
    const result = await api<CatalogResponse>(`/v1/catalog?${query}`, { signal: controller.signal, timeout: catalogRequestTimeoutMs });
    if (requestId !== productRequestId) return;
    products.value = reset ? result.items : [...products.value, ...result.items];
    nextCursor.value = result.nextCursor;
    if (reset) totalCount.value = result.totalCount ?? result.items.length;
  } catch (cause) { if (requestId === productRequestId) error.value = cause instanceof Error ? cause.message : "Katalogo užkrauti nepavyko"; }
  finally {
    if (requestId === productRequestId) {
      loading.value = false;
      if (productAbortController === controller) productAbortController = null;
    }
  }
}
async function loadFacets(value = filters.value, options: { force?: boolean } = {}) {
  const requestId = ++facetsRequestId;
  const query = apiParams(value);
  query.delete("sort");
  const key = query.toString();
  facetsError.value = "";
  let pending = pendingFacets.get(key);
  if (options.force && pending) {
    pending.controller.abort();
    pendingFacets.delete(key);
    pending = undefined;
  }
  if (pending) {
    // A forced refresh may already be running for this key. Join it before
    // consulting the in-memory or localStorage value, which may be older.
    facetsLoading.value = true;
  } else if (!options.force && key === lastFacetsKey && facets.value) {
    facetsLoading.value = false;
    return facets.value;
  } else if (!options.force && restoreCachedFacets(key)) {
    facetsLoading.value = false;
    return facets.value;
  } else {
    const controller = new AbortController();
    const promise = api<CatalogFacets>(`/v1/catalog/facets?${query}`, { signal: controller.signal, timeout: catalogRequestTimeoutMs });
    pending = { promise, controller };
    pendingFacets.set(key, pending);
    facetsLoading.value = true;
  }
  const request = pending.promise;
  try {
    const result = await request;
    if (pendingFacets.get(key) === pending) storeCachedFacets(key, result);
    if (requestId === facetsRequestId) {
      facets.value = result;
      lastFacetsKey = key;
    }
    return result;
  } catch {
    if (requestId === facetsRequestId) facetsError.value = facets.value
      ? "Filtrų atnaujinti nepavyko. Rodomi paskutiniai turimi filtrai."
      : "Filtrų įkelti nepavyko.";
    return null;
  } finally {
    if (pendingFacets.get(key) === pending) pendingFacets.delete(key);
    if (requestId === facetsRequestId) facetsLoading.value = false;
  }
}
async function updateFilters(value: Record<string, string>) {
  const next = { ...value };
  delete next.catalog_version;
  await router.push({ query: Object.fromEntries(Object.entries(next).filter(([, item]) => item)) });
}
async function selectCategory(category: string) {
  const next: Record<string, string> = { ...filters.value, category: filters.value.category === category ? "" : category };
  delete next.categories;
  for (const key of ["sizes", "other_sizes", "materials", "patterns", "features", "styles", "product_types"]) delete next[key];
  try {
    await updateFilters(next);
  } catch (cause) {
    loading.value = false;
    error.value = cause instanceof Error ? cause.message : "Kategorijos atidaryti nepavyko";
  }
}
const updateWatch = ({ id, isWatched }: { id: string; isWatched: boolean }) => {
  products.value = products.value.map((product) => product.id === id ? { ...product, isWatched } : product);
};
watch([() => route.path, () => route.query], () => {
  void Promise.all([load(true), loadFacets(filters.value)]);
}, { deep: true });
onMounted(() => {
  void Promise.all([loadFacets(filters.value), load()]);
});
onMounted(() => {
  handleFacetCacheInvalidation();
  window.addEventListener("storage", (event) => { if (event.key === "catalog-facets:invalidate") handleFacetCacheInvalidation(); });
  const saved = Number(localStorage.getItem("catalog-grid-columns"));
  if (saved === 3 || saved === 4) gridColumns.value = saved;
});
watch(gridColumns, (value) => localStorage.setItem("catalog-grid-columns", String(value)));
</script>

<template>
  <main class="catalog-page">
    <div class="catalog-layout">
      <aside class="category-nav" aria-label="Prekių kategorijos">
        <NuxtLink to="/?discount_min=10" class="category-sale">IŠPARDAVIMAS</NuxtLink>
        <NuxtLink to="/naujienos" class="category-news" :class="{ active: isNews }">Naujienos</NuxtLink>
        <CategoryTreeItem v-for="category in categoryTree" :key="category.id" :node="category" :selected-path="filters.category" :expanded="expandedRootPath === category.path" @select="selectCategory" @expand="expandedRootPath = $event" />
      </aside>
      <section class="results">
        <header class="catalog-hero">
          <p class="catalog-breadcrumbs">Vyrams <template v-if="isNews"><span>›</span> Naujienos</template><template v-else v-for="category in categoryTrail" :key="category.id"><span>›</span> {{ category.name }}</template></p>
          <div class="catalog-heading-row">
            <div class="catalog-title-row">
              <h1>{{ isNews ? "Naujienos" : catalogTitle }}</h1>
              <span class="catalog-count">{{ formattedCount }}</span>
            </div>
            <CatalogViewControls :grid-columns="gridColumns" :sort="filters.sort || 'newest'" @update:grid-columns="gridColumns = $event" @update:sort="updateFilters({ ...filters, sort: $event })" />
          </div>
        </header>
        <div class="catalog-mobile-toolbar"><button class="filter-trigger" @click="filtersOpen = true">Filtrai</button><label>Rūšiuoti<select :value="filters.sort || 'newest'" @change="updateFilters({ ...filters, sort: ($event.target as HTMLSelectElement).value })"><option v-for="option in catalogSortOptions" :key="option.value" :value="option.value">{{ option.label }}</option></select></label></div>
        <CatalogFilters :model-value="filters" :facets="facets" :total-count="totalCount" :open="filtersOpen" @update:model-value="updateFilters" @update:open="filtersOpen = $event" />
        <p v-if="facetsLoading" class="catalog-facets-status" role="status">Atnaujinami filtrai…</p>
        <p v-if="facetsError" class="error-state" role="alert">{{ facetsError }} <button type="button" @click="loadFacets(filters, { force: true })">Bandyti dar kartą</button></p>
        <div class="catalog-alert-row"><FilterAlertDialog :filters="filters" :total-count="totalCount" :title="isNews ? 'Naujienos' : catalogTitle" /></div>
        <p v-if="error" class="error-state">{{ error }}</p>
        <div v-if="loading && !products.length" class="loading-grid" :style="{ '--catalog-columns': gridColumns }" role="status" aria-label="Kraunamos prekės"><div v-for="n in 8" :key="n" /></div>
        <div v-else-if="products.length" class="product-grid-shell" :class="{ 'is-refreshing': loading }" :aria-busy="loading">
          <div v-if="loading" class="catalog-refresh-anchor">
            <div class="catalog-refresh-status" role="status" aria-live="polite">
              <span class="catalog-refresh-spinner" aria-hidden="true" />
              <span>Atnaujinamos prekės…</span>
            </div>
          </div>
          <div class="product-grid" :style="{ '--catalog-columns': gridColumns }"><ProductCard v-for="product in products" :key="product.id" :product="product" @watch-changed="updateWatch" /></div>
        </div>
        <div v-else class="empty-state"><h2>Produktų nerasta</h2><p>Pakeiskite filtrus arba paleiskite naują sinchronizavimą.</p></div>
        <button v-if="nextCursor" class="load-more" :disabled="loading" @click="load(false)">{{ loading ? "Kraunama…" : "Rodyti daugiau" }}</button>
      </section>
    </div>
  </main>
</template>
