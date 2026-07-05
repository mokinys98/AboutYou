<script setup lang="ts">
import { colorShadeLabels, type CatalogFacets, type ColorShade } from "@catalog/shared";

const props = defineProps<{ facets: CatalogFacets | null; modelValue: Record<string, string>; open: boolean }>();
const emit = defineEmits<{ "update:modelValue": [value: Record<string, string>]; "update:open": [value: boolean] }>();
const local = reactive<Record<string, string>>({ ...props.modelValue });
const expanded = ref(true);
const activeFilter = ref<string | null>(null);

watch(() => props.modelValue, (value) => {
  for (const key of Object.keys(local)) delete local[key];
  Object.assign(local, value);
}, { deep: true });

const selected = (key: string, value: string) => (local[key] || "").split(",").includes(value);
const toggle = (key: string, value: string) => {
  const values = new Set((local[key] || "").split(",").filter(Boolean));
  values.has(value) ? values.delete(value) : values.add(value);
  local[key] = Array.from(values).join(",");
  apply();
};
const apply = () => emit("update:modelValue", Object.fromEntries(Object.entries(local).filter(([, value]) => value)));
const setSale = (value: string) => { local.discount_min = value; apply(); };
const setComparison = (value: string) => { local.price_comparison = value; apply(); };
const clear = () => {
  const sort = local.sort;
  for (const key of Object.keys(local)) delete local[key];
  if (sort) local.sort = sort;
  apply();
};
const activeCount = (key: string) => (local[key] || "").split(",").filter(Boolean).length;
const groups = computed(() => [
  { key: "sizes", label: "Dydis", items: props.facets?.sizes ?? [] },
  { key: "color_shades", label: "Spalva", items: (props.facets?.colorShades ?? []).map((item) => ({ ...item, label: colorShadeLabels[item.value] })) },
  { key: "brands", label: "Prekės ženklas", items: props.facets?.brands ?? [] },
  { key: "other_sizes", label: "Kiti dydžiai", items: props.facets?.otherSizes ?? [] },
  { key: "materials", label: "Medžiaga", items: props.facets?.materials ?? [] },
  { key: "patterns", label: "Raštas", items: props.facets?.patterns ?? [] },
  { key: "features", label: "Prekės savybės", items: props.facets?.features ?? [] },
  { key: "styles", label: "Style", items: props.facets?.styles ?? [] },
  { key: "product_types", label: "Prekės rūšis", items: props.facets?.productTypes ?? [] }
]);
const visibleGroups = computed(() => groups.value.filter((group) => group.items.length > 1 || activeCount(group.key) > 0));
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
onMounted(() => document.addEventListener("pointerdown", onDocumentPointerDown));
onUnmounted(() => document.removeEventListener("pointerdown", onDocumentPointerDown));
</script>

<template>
  <div v-if="open" class="drawer-backdrop" @click.self="emit('update:open', false)" />
  <section class="filter-strip" :class="{ open }" aria-label="Katalogo filtrai">
    <div class="filter-mobile-head"><strong>Filtrai</strong><button class="close" @click="emit('update:open', false)">×</button></div>
    <details class="filter-popover price-filter" :open="activeFilter === 'price'" @toggle="onToggle('price', $event)">
      <summary>Kaina <span v-if="local.price_min || local.price_max" class="filter-count">•</span></summary>
      <div class="filter-menu"><div class="range-row"><label>Nuo<input v-model="local.price_min" inputmode="decimal" placeholder="0 €"></label><label>Iki<input v-model="local.price_max" inputmode="decimal" placeholder="500 €"></label></div><button class="filter-apply" @click="apply">Taikyti</button></div>
    </details>
    <details class="filter-popover sale-filter" :open="activeFilter === 'sale'" @toggle="onToggle('sale', $event)">
      <summary><span class="sale-mark">%</span> Išpardavimas <span v-if="local.discount_min || local.below_observed_30d" class="filter-count">•</span></summary>
      <div class="filter-menu">
        <label v-for="discount in ['10','20','30','40','50']" :key="discount" class="check"><input type="radio" name="discount" :checked="local.discount_min === discount" @change="setSale(discount)"><span>Nuo {{ discount }} %</span></label>
        <label class="check"><input v-model="local.below_observed_30d" true-value="true" false-value="" type="checkbox" @change="apply"><span>Dabar ≤ 30 d. minimumo</span></label>
        <fieldset class="comparison-options" :disabled="local.below_observed_30d !== 'true'"><legend>Palyginimo šaltinis</legend><label class="check"><input type="radio" name="comparison" :checked="(local.price_comparison || 'observed') === 'observed'" @change="setComparison('observed')"><span>Mūsų 30 d. istorija</span></label><label class="check"><input type="radio" name="comparison" :checked="local.price_comparison === 'source_lpl'" @change="setComparison('source_lpl')"><span>Šaltinio LPL</span></label></fieldset>
      </div>
    </details>
    <template v-for="(group, index) in visibleGroups" :key="group.key">
      <details v-show="expanded || index < 3" class="filter-popover" :open="activeFilter === group.key" @toggle="onToggle(group.key, $event)">
        <summary>{{ group.label }} <span v-if="activeCount(group.key)" class="filter-count">{{ activeCount(group.key) }}</span></summary>
        <div class="filter-menu">
          <label v-for="item in group.items.slice(0, 80)" :key="item.value" class="check">
            <input type="checkbox" :checked="selected(group.key, item.value)" @change="toggle(group.key, item.value)">
            <i v-if="group.key === 'color_shades'" class="swatch" :style="swatchStyle(item.value)" />
            <span>{{ 'label' in item && item.label ? item.label : item.value }}</span><small>{{ item.count }}</small>
          </label>
        </div>
      </details>
    </template>
    <button class="less-filters" type="button" @click="expanded = !expanded">{{ expanded ? "Mažiau filtrų" : "Daugiau filtrų" }} <span>{{ expanded ? "⌃" : "⌄" }}</span></button>
    <button v-if="Object.keys(local).some((key) => key !== 'sort' && local[key])" class="clear-filters" type="button" @click="clear">Išvalyti</button>
  </section>
</template>
