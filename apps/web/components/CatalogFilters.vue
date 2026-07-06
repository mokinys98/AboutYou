<script setup lang="ts">
import { colorShadeLabels, type CatalogFacets, type ColorShade } from "@catalog/shared";

type FacetItem = { value: string; count: number; label?: string };
type FilterGroup = { key: string; label: string; items: FacetItem[] };

const props = defineProps<{ facets: CatalogFacets | null; modelValue: Record<string, string>; open: boolean }>();
const emit = defineEmits<{ "update:modelValue": [value: Record<string, string>]; "update:open": [value: boolean] }>();
const local = reactive<Record<string, string>>({ ...props.modelValue });
const activeFilter = ref<string | null>(null);
const searches = reactive<Record<string, string>>({});

watch(() => props.modelValue, (value) => {
  for (const key of Object.keys(local)) delete local[key];
  Object.assign(local, value);
}, { deep: true });

const groups = computed<FilterGroup[]>(() => [
  { key: "sizes", label: "Dydis", items: props.facets?.sizes ?? [] },
  { key: "color_shades", label: "Spalva", items: (props.facets?.colorShades ?? []).map((item) => ({ ...item, label: colorShadeLabels[item.value] })) },
  { key: "brands", label: "Prekės ženklas", items: props.facets?.brands ?? [] },
  { key: "other_sizes", label: "Kiti dydžiai", items: props.facets?.otherSizes ?? [] },
  { key: "materials", label: "Medžiaga", items: props.facets?.materials ?? [] },
  { key: "patterns", label: "Raštas", items: props.facets?.patterns ?? [] },
  { key: "features", label: "Prekės savybės", items: props.facets?.features ?? [] },
  { key: "styles", label: "Stilius", items: props.facets?.styles ?? [] },
  { key: "product_types", label: "Prekės rūšis", items: props.facets?.productTypes ?? [] }
]);
const visibleGroups = computed(() => groups.value.filter((group) => group.items.length > 1 || activeCount(group.key) > 0));
const selected = (key: string, value: string) => (local[key] || "").split(",").includes(value);
const activeCount = (key: string) => (local[key] || "").split(",").filter(Boolean).length;
const filteredItems = (group: FilterGroup) => {
  const query = (searches[group.key] || "").trim().toLocaleLowerCase("lt");
  if (!query) return group.items.slice(0, 80);
  return group.items.filter((item) => (item.label || item.value).toLocaleLowerCase("lt").includes(query)).slice(0, 80);
};

const apply = () => emit("update:modelValue", Object.fromEntries(Object.entries(local).filter(([, value]) => value)));
const toggle = (key: string, value: string) => {
  const values = new Set((local[key] || "").split(",").filter(Boolean));
  values.has(value) ? values.delete(value) : values.add(value);
  local[key] = Array.from(values).join(",");
  apply();
};
const toggleSale = () => {
  local.discount_min = local.discount_min ? "" : "1";
  apply();
};
const clear = () => {
  const sort = local.sort;
  const category = local.category;
  for (const key of Object.keys(local)) delete local[key];
  if (sort) local.sort = sort;
  if (category) local.category = category;
  apply();
};
const removeFilter = (key: string, value?: string) => {
  if (value) {
    local[key] = (local[key] || "").split(",").filter((item) => item !== value).join(",");
  } else {
    local[key] = "";
    if (key === "price") { local.price_min = ""; local.price_max = ""; }
  }
  apply();
};
const activeChips = computed(() => {
  const chips: Array<{ key: string; value?: string; label: string }> = [];
  for (const group of groups.value) {
    for (const value of (local[group.key] || "").split(",").filter(Boolean)) {
      const item = group.items.find((candidate) => candidate.value === value);
      chips.push({ key: group.key, value, label: item?.label || value });
    }
  }
  if (local.discount_min) chips.push({ key: "discount_min", label: "Išpardavimas" });
  if (local.price_min || local.price_max) chips.push({ key: "price", label: `${local.price_min || "0"}–${local.price_max || "∞"} €` });
  return chips;
});

const shadeColors: Record<ColorShade, string> = {
  black: "#111", white: "#fff", off_white: "#f7f4e9", cream: "#f2e6c9", beige: "#d9c3a5", taupe: "#8b7d72",
  grey: "#999", charcoal: "#36454f", brown: "#764a2d", camel: "#c19a6b", copper: "#b87333", rust: "#b7410e",
  red: "#ce1e32", burgundy: "#800020", orange: "#ef7920", yellow: "#f2d229", mustard: "#d4a017", green: "#348351",
  olive: "#808000", khaki: "#9b8f55", mint: "#98d8b3", teal: "#008080", turquoise: "#40e0d0", blue: "#2855a5",
  navy: "#000080", purple: "#6b3f8e", lilac: "#c8a2c8", pink: "#ee9dba", rose: "#c08081", silver: "#c6c9cb",
  gold: "#c8a34b", multicolor: "conic-gradient(red,yellow,lime,aqua,blue,magenta,red)", other: "#eee"
};
const swatchStyle = (value: string) => ({ background: shadeColors[value as ColorShade] ?? shadeColors.other });
const onToggle = (key: string, event: Event) => {
  const details = event.currentTarget as HTMLDetailsElement;
  if (details.open) activeFilter.value = key;
  else if (activeFilter.value === key) activeFilter.value = null;
};
const onDocumentPointerDown = (event: PointerEvent) => {
  const target = event.target as Element | null;
  if (!target?.closest(".filter-popover")) activeFilter.value = null;
};
const onDocumentKeyDown = (event: KeyboardEvent) => {
  if (event.key === "Escape") {
    if (props.open) emit("update:open", false);
    activeFilter.value = null;
  }
};
onMounted(() => {
  document.addEventListener("pointerdown", onDocumentPointerDown);
  document.addEventListener("keydown", onDocumentKeyDown);
});
onUnmounted(() => {
  document.removeEventListener("pointerdown", onDocumentPointerDown);
  document.removeEventListener("keydown", onDocumentKeyDown);
});
</script>

<template>
  <div v-if="open" class="drawer-backdrop" @click.self="emit('update:open', false)" />
  <section class="filter-strip" :class="{ open }" aria-label="Katalogo filtrai">
    <div class="filter-mobile-head"><strong>Filtrai</strong><button class="close" type="button" aria-label="Uždaryti filtrus" @click="emit('update:open', false)">×</button></div>

    <details class="filter-popover price-filter" :open="activeFilter === 'price'" @toggle="onToggle('price', $event)">
      <summary>Kaina <span v-if="local.price_min || local.price_max" class="filter-count">1</span></summary>
      <div class="filter-menu"><div class="range-row"><label>Nuo<input v-model="local.price_min" inputmode="decimal" placeholder="0 €"></label><label>Iki<input v-model="local.price_max" inputmode="decimal" placeholder="500 €"></label></div><button class="filter-apply" type="button" @click="apply(); activeFilter = null">Taikyti</button></div>
    </details>

    <button class="sale-toggle" :class="{ active: Boolean(local.discount_min) }" type="button" role="switch" :aria-checked="Boolean(local.discount_min)" @click="toggleSale">
      <span>Išpardavimas</span><i aria-hidden="true" />
    </button>

    <template v-for="group in visibleGroups" :key="group.key">
      <details class="filter-popover" :open="activeFilter === group.key" @toggle="onToggle(group.key, $event)">
        <summary>{{ group.label }} <span v-if="activeCount(group.key)" class="filter-count">{{ activeCount(group.key) }}</span></summary>
        <div class="filter-menu">
          <label v-if="group.items.length > 12" class="filter-search"><span class="sr-only">Ieškoti</span><input v-model="searches[group.key]" type="search" :placeholder="`Ieškoti: ${group.label.toLocaleLowerCase('lt')}`"></label>
          <label v-for="item in filteredItems(group)" :key="item.value" class="check">
            <input type="checkbox" :checked="selected(group.key, item.value)" @change="toggle(group.key, item.value)">
            <i v-if="group.key === 'color_shades'" class="swatch" :style="swatchStyle(item.value)" />
            <span>{{ item.label || item.value }}</span><small>{{ item.count }}</small>
          </label>
          <p v-if="!filteredItems(group).length" class="filter-empty">Atitikmenų nėra</p>
        </div>
      </details>
    </template>

    <button v-if="activeChips.length" class="clear-filters" type="button" @click="clear">Išvalyti</button>
    <div v-if="activeChips.length" class="active-filter-chips" aria-label="Aktyvūs filtrai">
      <button v-for="chip in activeChips" :key="`${chip.key}-${chip.value || ''}`" type="button" @click="removeFilter(chip.key, chip.value)">{{ chip.label }} <span aria-hidden="true">×</span></button>
    </div>
    <button class="filter-mobile-apply" type="button" @click="emit('update:open', false)">Rodyti rezultatus</button>
  </section>
</template>
