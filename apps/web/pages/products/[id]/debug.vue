<script setup lang="ts">
import type { ProductDebugResponse } from "@catalog/shared";

const route = useRoute();
const api = useApi();
const response = ref<ProductDebugResponse | null>(null);
const error = ref("");
const search = ref("");
const copied = ref(false);

const json = computed(() => response.value?.raw ? JSON.stringify(response.value.raw.payload, null, 2) : "");
const visibleJson = computed(() => {
  const term = search.value.trim().toLocaleLowerCase("lt");
  if (!term) return json.value;
  return json.value.split("\n").filter((line) => line.toLocaleLowerCase("lt").includes(term)).join("\n");
});
const matchCount = computed(() => search.value.trim() ? visibleJson.value.split("\n").filter(Boolean).length : 0);
const filterFields = computed(() => response.value ? [
  ["Kategorijos", response.value.product.categories],
  ["Kategorijų keliai", response.value.product.categoryPaths],
  ["Spalvos originalas", response.value.product.colorOriginal ? [response.value.product.colorOriginal] : []],
  ["Spalvos šeima", [response.value.product.colorFamily]],
  ["Spalvos atspalvis", [response.value.product.colorShade]],
  ["Dydžiai", response.value.product.sizes],
  ["Kiti dydžiai", response.value.product.otherSizes],
  ["Medžiagos", response.value.product.materials],
  ["Raštai", response.value.product.patterns],
  ["Savybės", response.value.product.features],
  ["Stiliai", response.value.product.styles],
  ["Produkto tipai", response.value.product.productTypes]
] as Array<[string, string[]]> : []);

async function copyJson() {
  if (!json.value) return;
  await navigator.clipboard.writeText(json.value);
  copied.value = true;
  window.setTimeout(() => { copied.value = false; }, 1500);
}

onMounted(async () => {
  try {
    response.value = await api<ProductDebugResponse>(`/v1/products/${route.params.id}/debug`);
  } catch (cause: any) {
    const status = cause?.statusCode ?? cause?.status;
    error.value = status === 403 ? "Produkto debug duomenys prieinami tik administratoriams."
      : status === 404 ? "Produktas nerastas."
      : cause?.data?.error ?? "Debug duomenų užkrauti nepavyko.";
  }
});
</script>

<template>
  <main class="debug-page">
    <NuxtLink :to="`/products/${route.params.id}`" class="back">← Grįžti į produkto puslapį</NuxtLink>
    <p v-if="error" class="error-state">{{ error }}</p>
    <p v-else-if="!response">Kraunama…</p>
    <template v-else>
      <header class="debug-heading">
        <div><p class="eyebrow">PRODUKTO DEBUG</p><h1>{{ response.product.name }}</h1><p>{{ response.product.brand }} · {{ response.product.externalId }}</p></div>
        <a :href="response.product.productUrl" target="_blank" rel="noopener noreferrer" class="primary">ABOUT YOU ↗</a>
      </header>

      <section class="debug-section">
        <h2>Filtravimui naudojami duomenys</h2>
        <dl class="debug-fields">
          <div v-for="([label, values]) in filterFields" :key="label"><dt>{{ label }}</dt><dd><span v-if="values.length">{{ values.join(", ") }}</span><em v-else>nėra</em></dd></div>
        </dl>
      </section>

      <section class="debug-section">
        <h2>Spalvų ir dydžių variantai</h2>
        <pre>{{ JSON.stringify({ colorOptions: response.detail.colorOptions, sizeOptions: response.detail.sizeOptions }, null, 2) }}</pre>
      </section>

      <section class="debug-section">
        <h2>Nuotraukos ({{ response.product.imageUrls.length }})</h2>
        <div class="debug-images"><a v-for="url in response.product.imageUrls" :key="url" :href="url" target="_blank" rel="noopener noreferrer"><img :src="url" :alt="response.product.name"><small>{{ url }}</small></a></div>
      </section>

      <section class="debug-section">
        <h2>Sinchronizavimas</h2>
        <pre>{{ JSON.stringify({ detail: response.detail, raw: response.raw ? { ...response.raw, payload: "[rodoma žemiau]" } : null }, null, 2) }}</pre>
      </section>

      <section class="debug-section raw-json">
        <div class="debug-section-heading"><div><h2>Pilnas sanitizuotas API payload</h2><p v-if="response.raw">{{ response.raw.sourceEndpoint }} · {{ response.raw.fetchedAt }}</p></div><button v-if="response.raw" class="secondary" @click="copyJson">{{ copied ? "Nukopijuota" : "Kopijuoti JSON" }}</button></div>
        <p v-if="!response.raw" class="detail-sync-state">Raw payload šiam produktui dar nesurinktas.</p>
        <template v-else>
          <label class="json-search">Ieškoti JSON <input v-model="search" type="search" placeholder="Pvz. category, color, size"><small v-if="search">Atitinkančių eilučių: {{ matchCount }}</small></label>
          <pre>{{ visibleJson || "Atitikmenų nėra." }}</pre>
        </template>
      </section>
    </template>
  </main>
</template>
