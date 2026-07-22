<script setup lang="ts">
import type { ProductDetailResponse, ProductDetailSectionKey } from "@catalog/shared";

const route = useRoute();
const api = useApi();
const product = ref<ProductDetailResponse | null>(null);
const error = ref("");
const watchError = ref("");
const watchPending = ref(false);

const sectionLabels: Record<ProductDetailSectionKey, string> = {
  size_and_fit: "Dydis ir forma",
  measurements: "Išmatavimai",
  material_composition: "Medžiagų sudėtis",
  design_and_extras: "Dizainas ir priedai"
};
const sectionOrder: ProductDetailSectionKey[] = [
  "size_and_fit", "measurements", "material_composition", "design_and_extras"
];
const detailSections = computed(() => [...(product.value?.detail.sections ?? [])]
  .sort((left, right) => sectionOrder.indexOf(left.key) - sectionOrder.indexOf(right.key)));
const detailStatus = computed(() => {
  switch (product.value?.detail.status) {
    case "complete": return null;
    case "retryable_error": return "Produkto duomenų sinchronizavimas laikinai nepavyko ir bus kartojamas.";
    case "blocked_schema": return "ABOUT YOU pakeitė produkto duomenų formatą. Duomenys nerodomi, kol parseris nebus atnaujintas.";
    case "source_unavailable": return "Produkto puslapis šaltinyje nebepasiekiamas.";
    default: return "Produkto papildomi duomenys dar renkami.";
  }
});
const format = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("lt-LT", {
  style: "currency", currency: product.value?.currency || "EUR"
}).format(value / 100);
const formatObservedAt = (value: string) => new Intl.DateTimeFormat("lt-LT", {
  dateStyle: "medium", timeStyle: "short"
}).format(new Date(value));

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
  } finally {
    watchPending.value = false;
  }
}

onMounted(async () => {
  try { product.value = await api<ProductDetailResponse>(`/v1/products/${route.params.id}`); }
  catch (cause) { error.value = cause instanceof Error ? cause.message : "Produkto užkrauti nepavyko"; }
});
</script>

<template>
  <main class="detail-page">
    <NuxtLink to="/" class="back">← Grįžti į katalogą</NuxtLink>
    <p v-if="error" class="error-state">{{ error }}</p>
    <template v-else-if="product">
      <section class="detail-grid">
        <div
          v-if="product.imageUrls.length"
          class="detail-gallery"
          :class="`detail-gallery-count-${Math.min(product.imageUrls.length, 7)}`"
          aria-label="Produkto nuotraukos"
        >
          <div v-for="(imageUrl, index) in product.imageUrls" :key="`${imageUrl}-${index}`" class="detail-gallery-item">
            <img :src="imageUrl" :alt="`${product.name} — nuotrauka ${index + 1}`" :loading="index === 0 ? 'eager' : 'lazy'">
          </div>
        </div>
        <div v-else class="detail-gallery detail-gallery-empty"><div class="image-placeholder">Nuotraukos nėra</div></div>
        <div>
          <div class="detail-heading">
            <div>
              <div class="detail-brand-line"><p class="eyebrow">{{ product.brand }}</p><BrandTierRibbon :tier="product.brandTier" compact /></div>
              <h1>{{ product.name }}</h1>
            </div>
            <button class="detail-watch" :class="{ active: product.isWatched }" :disabled="watchPending" :aria-pressed="product.isWatched" @click="toggleWatch">
              {{ product.isWatched ? "♥ Stebima" : "♡ Stebėti" }}
            </button>
          </div>
          <p v-if="watchError" class="error">{{ watchError }}</p>
          <p class="detail-price">{{ format(product.currentPrice) }}</p>
          <p v-if="product.originalPrice"><s>{{ format(product.originalPrice) }}</s></p>
          <dl>
            <div><dt>30 d. mūsų minimumas</dt><dd>{{ format(product.observedMin30d) }}</dd></div>
            <div><dt>Šaltinio LPL</dt><dd>{{ format(product.sourceLpl30) }}</dd></div>
            <div><dt>Spalva</dt><dd>{{ product.colorOriginal || product.colorShade }}</dd></div>
          </dl>
          <a :href="product.productUrl" target="_blank" rel="noopener noreferrer" class="primary external">Atidaryti ABOUT YOU ↗</a>
        </div>
      </section>

      <p v-if="detailStatus" class="detail-sync-state" :class="`is-${product.detail.status}`">{{ detailStatus }}</p>
      <section v-if="product.detail.status === 'complete'" class="product-metadata">
        <article class="metadata-section color-size-section">
          <h2>Spalva ir dydžiai</h2>
          <div v-if="product.detail.colorOptions.length" class="metadata-options">
            <span v-for="option in product.detail.colorOptions" :key="`${option.externalId}-${option.label}`" :class="{ selected: option.selected }">{{ option.label }}</span>
          </div>
          <p v-else class="source-absent">Šaltinis spalvos pasirinkimų nepateikia.</p>
          <div v-if="product.detail.sizeOptions.length" class="size-options">
            <span v-for="option in product.detail.sizeOptions" :key="option.externalId" :class="{ unavailable: !option.selectable, selected: option.selected }">
              {{ option.label }}<small>{{ option.selectable ? "Yra" : "Išparduota" }}</small>
            </span>
          </div>
          <p v-else class="source-absent">Šaltinis dydžių nepateikia.</p>
        </article>

        <article v-for="section in detailSections" :key="section.key" class="metadata-section">
          <h2>{{ sectionLabels[section.key] }}</h2>
          <p v-if="section.status === 'source_absent'" class="source-absent">Šaltinis šios sekcijos nepateikia.</p>
          <dl v-else class="metadata-list">
            <div v-for="(item, index) in section.items" :key="`${section.key}-${index}`">
              <dt v-if="item.label">{{ item.label }}</dt>
              <dd>{{ item.value }}<span v-if="item.unit && !item.value.includes(item.unit)"> {{ item.unit }}</span></dd>
            </div>
          </dl>
        </article>
      </section>

      <section v-if="product.priceChanges.length" class="history">
        <h2>Kainos pokyčiai</h2>
        <div class="history-list">
          <div v-for="change in product.priceChanges" :key="change.observed_at">
            <time>{{ formatObservedAt(change.observed_at) }}</time><strong>{{ format(change.price) }}</strong>
            <span v-if="change.original_price !== null">pradinė {{ format(change.original_price) }}</span>
          </div>
        </div>
      </section>
    </template>
  </main>
</template>
