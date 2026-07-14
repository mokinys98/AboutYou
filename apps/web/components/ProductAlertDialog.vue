<script setup lang="ts">
import type { Alert, ProductAlertConditions } from "@catalog/shared";

type SizeOption = { externalId: string; label: string; selectable: boolean };
const props = withDefaults(defineProps<{
  product: { id: string; name: string; brand: string; currentPrice: number; currency: string };
  sizeOptions?: SizeOption[];
  compact?: boolean;
}>(), { sizeOptions: () => [], compact: false });
const emit = defineEmits<{ saved: [value: { id: string; isWatched: true }] }>();
const api = useApi();
const open = ref(false); const loading = ref(false); const saving = ref(false); const error = ref("");
const existing = ref<Extract<Alert, { kind: "product" }> | null>(null);
const name = ref(""); const price = ref("");
const belowObserved30d = ref(true); const belowSourceLpl30d = ref(true); const backInCatalog = ref(true);
const selectedSizes = ref<string[]>([]);

const allSizes = computed(() => {
  const known = new Map(props.sizeOptions.map((size) => [size.externalId, { id: size.externalId, label: size.label }]));
  for (const size of existing.value?.conditions.sizeOptions ?? []) if (!known.has(size.id)) known.set(size.id, size);
  return [...known.values()];
});

async function show() {
  open.value = true; loading.value = true; error.value = "";
  try {
    const alerts = await api<Alert[]>("/v1/alerts");
    existing.value = alerts.find((alert): alert is Extract<Alert, { kind: "product" }> => alert.kind === "product" && alert.product.id === props.product.id) ?? null;
    const conditions = existing.value?.conditions;
    name.value = existing.value?.name ?? `${props.product.brand} ${props.product.name}`.trim();
    price.value = conditions?.priceBelow !== undefined ? String(conditions.priceBelow / 100) : "";
    belowObserved30d.value = conditions?.belowObserved30d ?? true;
    belowSourceLpl30d.value = conditions?.belowSourceLpl30d ?? true;
    backInCatalog.value = conditions?.backInCatalog ?? true;
    selectedSizes.value = conditions?.sizeOptions.map((size) => size.id) ?? [];
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Alerto įkelti nepavyko"; }
  finally { loading.value = false; }
}

async function save() {
  saving.value = true; error.value = "";
  const parsedPrice = price.value.trim() ? Math.round(Number(price.value.replace(",", ".")) * 100) : undefined;
  if (parsedPrice !== undefined && (!Number.isFinite(parsedPrice) || parsedPrice < 0)) {
    error.value = "Įveskite teisingą kainą"; saving.value = false; return;
  }
  const conditions: ProductAlertConditions = {
    ...(parsedPrice === undefined ? {} : { priceBelow: parsedPrice }),
    belowObserved30d: belowObserved30d.value,
    belowSourceLpl30d: belowSourceLpl30d.value,
    backInCatalog: backInCatalog.value,
    sizeOptions: allSizes.value.filter((size) => selectedSizes.value.includes(size.id))
  };
  try {
    if (existing.value) {
      existing.value = await api(`/v1/alerts/${existing.value.id}`, { method: "PATCH", body: { name: name.value, conditions } });
    } else {
      existing.value = await api("/v1/alerts", { method: "POST", body: { kind: "product", productId: props.product.id, name: name.value, conditions } });
    }
    emit("saved", { id: props.product.id, isWatched: true });
    open.value = false;
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Alerto išsaugoti nepavyko"; }
  finally { saving.value = false; }
}
</script>

<template>
  <button type="button" class="alert-bell" :class="{ compact }" aria-label="Produkto alerto nustatymai" @click.stop.prevent="show">🔔</button>
  <Teleport to="body">
    <div v-if="open" class="modal-backdrop" @click.self="open = false">
      <section class="alert-dialog" role="dialog" aria-modal="true" aria-labelledby="product-alert-title">
        <button class="dialog-close" type="button" aria-label="Uždaryti" @click="open = false">×</button>
        <p class="eyebrow">TELEGRAM ALERTAS</p>
        <h2 id="product-alert-title">{{ product.brand }} {{ product.name }}</h2>
        <p v-if="loading">Kraunama…</p>
        <form v-else @submit.prevent="save">
          <label class="field">Pavadinimas<input v-model="name" required maxlength="120"></label>
          <label class="field">Pranešti, kai kaina ne didesnė nei<input v-model="price" inputmode="decimal" :placeholder="`${(product.currentPrice / 100).toFixed(2)} €`"></label>
          <label class="check alert-check"><input v-model="belowObserved30d" type="checkbox"> Naujas 30 d. kainos minimumas</label>
          <label class="check alert-check"><input v-model="belowSourceLpl30d" type="checkbox"> Kaina pasiekia arba nukrenta žemiau LPL</label>
          <label class="check alert-check"><input v-model="backInCatalog" type="checkbox"> Prekė sugrįžta į katalogą</label>
          <fieldset v-if="allSizes.length" class="alert-sizes"><legend>Pasirinkti dydžiai atsiranda</legend><label v-for="size in allSizes" :key="size.id" class="check"><input v-model="selectedSizes" type="checkbox" :value="size.id"> {{ size.label }}</label></fieldset>
          <p v-if="error" class="error">{{ error }}</p>
          <div class="dialog-actions"><button type="button" @click="open = false">Atšaukti</button><button class="primary" :disabled="saving">{{ saving ? "Saugoma…" : "Išsaugoti alertą" }}</button></div>
        </form>
      </section>
    </div>
  </Teleport>
</template>
