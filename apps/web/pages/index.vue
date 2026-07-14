<script setup lang="ts">
import { buildCategoryTree, clothingCategoryTree, type CatalogCategoryFacet, type CatalogFacets, type CatalogResponse } from "@catalog/shared";
definePageMeta({ alias: ["/naujienos"] });
const route = useRoute(); const router = useRouter(); const api = useApi();
const isNews = computed(() => route.path === "/naujienos");
const products = ref<CatalogResponse["items"]>([]); const facets = ref<CatalogFacets | null>(null);
const nextCursor = ref<string | null>(null); const loading = ref(true); const error = ref(""); const filtersOpen = ref(false);
const totalCount = ref(0);
const gridColumns = ref<3 | 4>(3);
const expandedRootPath = ref<string | null>(null);
let lastFacetsKey = "";
let pendingFacets: { key: string; request: Promise<CatalogFacets | null> } | null = null;
const facetsCacheTtlMs = 24 * 60 * 60 * 1000;
const facetsCachePrefix = "catalog-facets:v1:";
const filterKeys = ["brands", "brand_tiers", "categories", "category", "colors", "color_shades", "sources", "sizes", "other_sizes", "materials", "patterns", "features", "styles", "product_types", "premium", "exclude_basics", "exclude_accessories", "price_min", "price_max", "discount_min", "below_observed_30d", "price_comparison", "sort"];
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
function hydrateFacetsFromCache(key: string) {
  if (restoreCachedFacets(key)) return;
  if (lastFacetsKey !== key) {
    facets.value = null;
    lastFacetsKey = "";
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
async function load(reset = true) {
  loading.value = true; error.value = "";
  try {
    const query = apiParams(filters.value);
    if (!reset && nextCursor.value) query.set("cursor", nextCursor.value);
    const result = await api<CatalogResponse>(`/v1/catalog?${query}`);
    products.value = reset ? result.items : [...products.value, ...result.items];
    nextCursor.value = result.nextCursor;
    if (reset) totalCount.value = result.totalCount ?? result.items.length;
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Katalogo užkrauti nepavyko"; }
  finally { loading.value = false; }
}
async function loadFacets(value = filters.value, options: { force?: boolean } = {}) {
  const query = apiParams(value);
  query.delete("sort");
  const key = query.toString();
  if (key === lastFacetsKey && facets.value && !options.force) return facets.value;
  if (!options.force && restoreCachedFacets(key)) return facets.value;
  if (pendingFacets?.key === key) return pendingFacets.request;
  const request = api<CatalogFacets>(`/v1/catalog/facets?${query}`).catch(() => null);
  pendingFacets = { key, request };
  const result = await request;
  if (pendingFacets?.request === request) pendingFacets = null;
  if (result) {
    facets.value = result;
    lastFacetsKey = key;
    storeCachedFacets(key, result);
  }
  return result;
}
async function updateFilters(value: Record<string, string>) { await router.push({ query: Object.fromEntries(Object.entries(value).filter(([, item]) => item)) }); }
async function selectCategory(category: string) {
  const next: Record<string, string> = { ...filters.value, category: filters.value.category === category ? "" : category };
  delete next.categories;
  for (const key of ["sizes", "other_sizes", "materials", "patterns", "features", "styles", "product_types"]) delete next[key];
  loading.value = true;
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
watch(() => route.query, () => {
  const query = apiParams(filters.value);
  query.delete("sort");
  hydrateFacetsFromCache(query.toString());
  void Promise.all([load(true), loadFacets(filters.value, { force: true })]);
}, { deep: true });
onMounted(() => {
  const query = apiParams(filters.value);
  query.delete("sort");
  hydrateFacetsFromCache(query.toString());
  void Promise.all([loadFacets(filters.value), load()]);
});
onMounted(() => {
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
        <div class="catalog-mobile-toolbar"><button class="filter-trigger" @click="filtersOpen = true">Filtrai</button><label>Rūšiuoti<select :value="filters.sort || 'newest'" @change="updateFilters({ ...filters, sort: ($event.target as HTMLSelectElement).value })"><option value="newest">Naujausi</option><option value="price_asc">Kaina ↑</option><option value="price_desc">Kaina ↓</option><option value="source_lpl_desc">Paskutinė mažiausia kaina: nuo didžiausios</option><option value="source_lpl_asc">Paskutinė mažiausia kaina: nuo mažiausios</option><option value="discount_desc">Nuolaida</option></select></label></div>
        <CatalogFilters :model-value="filters" :facets="facets" :open="filtersOpen" @update:model-value="updateFilters" @update:open="filtersOpen = $event" />
        <p v-if="error" class="error-state">{{ error }}</p>
        <div v-else-if="loading && !products.length" class="loading-grid" :style="{ '--catalog-columns': gridColumns }" role="status" aria-label="Kraunamos prekės"><div v-for="n in 8" :key="n" /></div>
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
