<script setup lang="ts">
import { colorFamilies, type CatalogFacets } from "@catalog/shared";
const props = defineProps<{ facets: CatalogFacets | null; modelValue: Record<string, string>; open: boolean }>();
const emit = defineEmits<{ "update:modelValue": [value: Record<string, string>]; "update:open": [value: boolean] }>();
const local = reactive({ ...props.modelValue });
watch(() => props.modelValue, (value) => Object.assign(local, value));
const toggle = (key: string, value: string) => {
  const values = new Set((local[key] || "").split(",").filter(Boolean));
  values.has(value) ? values.delete(value) : values.add(value);
  local[key] = Array.from(values).join(",");
};
const selected = (key: string, value: string) => (local[key] || "").split(",").includes(value);
const apply = () => { emit("update:modelValue", { ...local }); emit("update:open", false); };
const clear = () => { Object.keys(local).forEach((key) => delete local[key]); apply(); };
const labels: Record<string, string> = { black: "Juoda", white: "Balta", grey: "Pilka", brown: "Ruda", beige: "Smėlio", red: "Raudona", orange: "Oranžinė", yellow: "Geltona", green: "Žalia", blue: "Mėlyna", purple: "Violetinė", pink: "Rožinė", silver: "Sidabrinė", gold: "Auksinė", multicolor: "Įvairiaspalvė", other: "Kita" };
</script>

<template>
  <div v-if="open" class="drawer-backdrop" @click.self="emit('update:open', false)" />
  <aside class="filters" :class="{ open }">
    <div class="filter-head"><h2>Filtrai</h2><button class="mobile-only close" @click="emit('update:open', false)">×</button></div>
    <details open><summary>Prekės ženklas</summary><label v-for="item in facets?.brands.slice(0, 30)" :key="item.value" class="check"><input type="checkbox" :checked="selected('brands', item.value)" @change="toggle('brands', item.value)"><span>{{ item.value }}</span><small>{{ item.count }}</small></label></details>
    <details open><summary>Kategorija</summary><label v-for="item in facets?.categories.slice(0, 30)" :key="item.value" class="check"><input type="checkbox" :checked="selected('categories', item.value)" @change="toggle('categories', item.value)"><span>{{ item.value }}</span><small>{{ item.count }}</small></label></details>
    <details><summary>Spalva</summary><label v-for="color in colorFamilies" :key="color" class="check"><input type="checkbox" :checked="selected('colors', color)" @change="toggle('colors', color)"><i class="swatch" :class="`swatch-${color}`" /><span>{{ labels[color] }}</span></label></details>
    <details open><summary>Kaina</summary><div class="range-row"><label>Nuo<input v-model="local.price_min" inputmode="decimal" placeholder="0"></label><label>Iki<input v-model="local.price_max" inputmode="decimal" placeholder="500"></label></div></details>
    <label class="check special"><input v-model="local.below_observed_30d" true-value="true" false-value="" type="checkbox"><span>Dabar ≤ 30 d. minimumo</span></label>
    <div class="filter-actions"><button class="secondary" @click="clear">Išvalyti</button><button class="primary" @click="apply">Taikyti</button></div>
  </aside>
</template>

