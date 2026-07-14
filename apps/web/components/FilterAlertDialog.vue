<script setup lang="ts">
import type { Alert, CatalogAlertFilters, TelegramConnection } from "@catalog/shared";

const props = defineProps<{ filters: Record<string, string>; totalCount: number; title: string }>();
const api = useApi();
const open = ref(false); const saving = ref(false); const error = ref(""); const success = ref("");
const name = ref(""); const connection = ref<TelegramConnection | null>(null);
const meaningful = computed(() => Object.entries(props.filters).some(([key, value]) => value && key !== "sort"));

function list(key: string) { return props.filters[key]?.split(",").map((value) => value.trim()).filter(Boolean) ?? []; }
function alertFilters(): Partial<CatalogAlertFilters> {
  return {
    brands: list("brands"), brandTiers: list("brand_tiers") as CatalogAlertFilters["brandTiers"], sources: list("sources"),
    categories: list("categories"), categoryPath: props.filters.category || undefined,
    colors: list("colors") as CatalogAlertFilters["colors"], colorShades: list("color_shades") as CatalogAlertFilters["colorShades"],
    sizes: list("sizes"), otherSizes: list("other_sizes"), materials: list("materials"), patterns: list("patterns"),
    features: list("features"), styles: list("styles"), productTypes: list("product_types"),
    isPremium: props.filters.premium === "true", excludeBasics: props.filters.exclude_basics === "true",
    excludeAccessories: props.filters.exclude_accessories === "true",
    priceMin: props.filters.price_min ? Math.round(Number(props.filters.price_min) * 100) : undefined,
    priceMax: props.filters.price_max ? Math.round(Number(props.filters.price_max) * 100) : undefined,
    discountMin: props.filters.discount_min ? Number(props.filters.discount_min) : undefined,
    belowObserved30d: props.filters.below_observed_30d === "true",
    priceComparison: props.filters.price_comparison === "source_lpl" ? "source_lpl" : "observed"
  };
}
async function show() {
  open.value = true; error.value = ""; success.value = "";
  name.value = `${props.title} – naujos prekės`;
  connection.value = await api<TelegramConnection>("/v1/telegram/connection").catch(() => null);
}
async function save() {
  saving.value = true; error.value = "";
  try {
    await api<Alert>("/v1/alerts", { method: "POST", body: { kind: "filter", name: name.value, filters: alertFilters(), conditions: { newMatches: true } } });
    success.value = "Alertas sukurtas";
    setTimeout(() => { open.value = false; }, 650);
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Alerto sukurti nepavyko"; }
  finally { saving.value = false; }
}
</script>

<template>
  <button class="filter-alert-button" type="button" :disabled="!meaningful" :title="meaningful ? 'Sukurti alertą šiems filtrams' : 'Pirma pasirinkite bent vieną filtrą'" @click="show">🔔 <span>Sukurti priminimą</span></button>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" @click.self="open = false">
      <section class="alert-dialog" role="dialog" aria-modal="true" aria-labelledby="filter-alert-title">
        <button class="dialog-close" type="button" aria-label="Uždaryti" @click="open = false">×</button>
        <p class="eyebrow">FILTRO ALERTAS</p><h2 id="filter-alert-title">Pranešti apie naujas prekes</h2>
        <p>Pagal šiuos filtrus dabar rodoma <strong>{{ totalCount }}</strong> prekių. Jos nebus siunčiamos – pranešime tik apie naujai atsiradusias.</p>
        <p v-if="connection && !connection.connected" class="alert-notice">Telegram dar neprijungtas. Alertas veiks, o Telegram galėsite prijungti profilyje.</p>
        <form @submit.prevent="save">
          <label class="field">Alerto pavadinimas<input v-model="name" required maxlength="120"></label>
          <p v-if="error" class="error">{{ error }}</p><p v-if="success" class="success-state">{{ success }}</p>
          <div class="dialog-actions"><button type="button" @click="open = false">Atšaukti</button><button class="primary" :disabled="saving">{{ saving ? "Kuriama…" : "Sukurti alertą" }}</button></div>
        </form>
      </section>
    </div>
  </Teleport>
</template>
