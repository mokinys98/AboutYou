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
const HOVER_DELAY_MS = 750;
const IMAGE_STEP_MS = 900;
const MAX_CAROUSEL_IMAGES = 6;
const carouselImages = computed(() => props.product.imageUrls.slice(0, MAX_CAROUSEL_IMAGES));
const carouselStarted = ref(false);
const desiredImageIndex = ref(0);
const loadedImageIndexes = ref(new Set<number>([0]));
let hoverDelay: ReturnType<typeof setTimeout> | undefined;
let imageStep: ReturnType<typeof setInterval> | undefined;

watch(() => props.product.isWatched, (value) => { watched.value = value; });
watch(() => props.product.id, () => {
  stopCarousel();
  loadedImageIndexes.value = new Set([0]);
});
const format = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("lt-LT", { style: "currency", currency: props.product.currency }).format(value / 100);
const discount = computed(() => Math.round(props.product.discountPct));
const lowestPrice = computed(() => props.product.sourceLpl30 ?? props.product.observedMin30d);
const lowestLabel = computed(() => props.product.sourceLpl30 !== null ? "Paskutinė mažiausia kaina" : "Mūsų 30 d. mažiausia kaina");
const activeImageIndex = computed(() => loadedImageIndexes.value.has(desiredImageIndex.value) ? desiredImageIndex.value : 0);

function supportsDesktopHover() {
  return import.meta.client && window.matchMedia("(hover: hover) and (pointer: fine)").matches;
}

function clearCarouselTimers() {
  clearTimeout(hoverDelay);
  clearInterval(imageStep);
  hoverDelay = undefined;
  imageStep = undefined;
}

function beginImageCycle(startIndex = 1) {
  if (carouselImages.value.length < 2) return;
  clearCarouselTimers();
  carouselStarted.value = true;
  desiredImageIndex.value = Math.min(startIndex, carouselImages.value.length - 1);
  imageStep = setInterval(() => {
    desiredImageIndex.value = desiredImageIndex.value >= carouselImages.value.length - 1
      ? 1
      : desiredImageIndex.value + 1;
  }, IMAGE_STEP_MS);
}

function onImageEnter() {
  if (!supportsDesktopHover() || carouselImages.value.length < 2) return;
  clearCarouselTimers();
  hoverDelay = setTimeout(() => beginImageCycle(), HOVER_DELAY_MS);
}

function stopCarousel() {
  clearCarouselTimers();
  carouselStarted.value = false;
  desiredImageIndex.value = 0;
}

function selectImage(direction: -1 | 1) {
  if (!supportsDesktopHover() || carouselImages.value.length < 2) return;
  clearCarouselTimers();
  carouselStarted.value = true;
  const last = carouselImages.value.length - 1;
  const next = desiredImageIndex.value + direction;
  desiredImageIndex.value = next < 0 ? last : next > last ? 0 : next;
}

function markImageLoaded(index: number) {
  loadedImageIndexes.value = new Set([...loadedImageIndexes.value, index]);
}

onBeforeUnmount(clearCarouselTimers);
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
  <article class="product-card" :class="{ 'product-card-carousel-active': carouselStarted }" @mouseenter="onImageEnter" @mouseleave="stopCarousel">
    <a :href="product.productUrl" class="product-card-target" target="_blank" rel="noopener noreferrer" :aria-label="`Atidaryti ${product.name} ABOUT YOU puslapyje`" />
    <div class="product-image-wrap">
      <template v-if="carouselImages[0]">
        <img
          v-for="(imageUrl, index) in carouselImages"
          v-show="index === 0 || carouselStarted"
          :key="`${imageUrl}-${index}`"
          :src="index === 0 || carouselStarted ? imageUrl : undefined"
          :alt="index === activeImageIndex ? `${product.name} — ${index + 1}` : ''"
          class="product-image product-carousel-image"
          :class="{ active: index === activeImageIndex }"
          :loading="index === 0 ? 'lazy' : 'eager'"
          :aria-hidden="index !== activeImageIndex"
          @load="markImageLoaded(index)"
        >
      </template>
      <div v-else class="image-placeholder">Nuotraukos nėra</div>
      <BrandTierRibbon :tier="product.brandTier" />
      <span v-if="discount" class="discount-badge">-{{ discount }}%</span>
      <template v-if="carouselImages.length > 1">
        <button type="button" class="product-image-arrow previous" aria-label="Ankstesnė produkto nuotrauka" @click.stop.prevent="selectImage(-1)">
          <svg aria-hidden="true" viewBox="0 0 24 24"><path d="m15 5-7 7 7 7" /></svg>
        </button>
        <div class="product-image-dots" aria-hidden="true">
          <span v-for="(_, index) in carouselImages" :key="index" :class="{ active: index === activeImageIndex }" />
        </div>
        <button type="button" class="product-image-arrow next" aria-label="Kita produkto nuotrauka" @click.stop.prevent="selectImage(1)">
          <svg aria-hidden="true" viewBox="0 0 24 24"><path d="m9 5 7 7-7 7" /></svg>
        </button>
      </template>
    </div>
    <div class="product-card-actions">
      <button class="watch-button" :class="{ active: watched }" :disabled="watchPending" :aria-label="watched ? 'Pašalinti iš stebimų prekių' : 'Stebėti prekę'" :aria-pressed="watched" @click.stop.prevent="toggleWatch">{{ watched ? "♥" : "♡" }}</button>
      <ProductAlertDialog v-if="showAlert" :product="product" @saved="onAlertSaved" />
      <button class="watch-button product-page-button" type="button" aria-label="Produkto puslapis" :aria-pressed="false" @click.stop.prevent="navigateTo(`/products/${product.id}`)">
        <svg aria-hidden="true" viewBox="0 0 24 24"><path d="M6 8h12l1 12H5L6 8Zm3 2V7a3 3 0 0 1 6 0v3" /></svg>
      </button>
      <button v-if="debugEnabled" class="watch-button product-debug-button" type="button" aria-label="Produkto debug informacija" @click.stop.prevent="navigateTo(`/products/${product.id}/debug`)">&lt;/&gt;</button>
    </div>
    <div class="product-copy">
      <p class="product-brand">{{ product.brand || product.source }}</p>
      <span class="product-name">{{ product.name }}</span>
      <p class="catalog-price">{{ format(product.currentPrice) }}</p>
      <p v-if="product.originalPrice !== null" class="price-note">Pradinė kaina: {{ format(product.originalPrice) }}</p>
      <p v-if="lowestPrice !== null" class="price-note">{{ lowestLabel }}: {{ format(lowestPrice) }}</p>
    </div>
  </article>
</template>
