<script setup lang="ts">
const props = defineProps<{ gridColumns: 3 | 4; sort: string }>();
const emit = defineEmits<{
  "update:gridColumns": [value: 3 | 4];
  "update:sort": [value: string];
}>();

const root = ref<HTMLElement | null>(null);
const activeMenu = ref<"view" | "sort" | null>(null);
const sortOptions = [
  { value: "newest", label: "Naujausi" },
  { value: "price_asc", label: "Kaina: nuo mažiausios" },
  { value: "price_desc", label: "Kaina: nuo didžiausios" },
  { value: "source_lpl_desc", label: "Paskutinė mažiausia kaina: nuo didžiausios" },
  { value: "source_lpl_asc", label: "Paskutinė mažiausia kaina: nuo mažiausios" },
  { value: "discount_desc", label: "Didžiausia nuolaida" }
];
const currentSort = computed(() => sortOptions.find((option) => option.value === props.sort)?.label ?? "Naujausi");

function toggle(menu: "view" | "sort") {
  activeMenu.value = activeMenu.value === menu ? null : menu;
}
function selectColumns(value: 3 | 4) {
  emit("update:gridColumns", value);
  activeMenu.value = null;
}
function selectSort(value: string) {
  emit("update:sort", value);
  activeMenu.value = null;
}
function onPointerDown(event: PointerEvent) {
  if (!root.value?.contains(event.target as Node)) activeMenu.value = null;
}
function onKeyDown(event: KeyboardEvent) {
  if (event.key === "Escape") activeMenu.value = null;
}
onMounted(() => {
  document.addEventListener("pointerdown", onPointerDown);
  document.addEventListener("keydown", onKeyDown);
});
onUnmounted(() => {
  document.removeEventListener("pointerdown", onPointerDown);
  document.removeEventListener("keydown", onKeyDown);
});
</script>

<template>
  <div ref="root" class="catalog-view-controls">
    <div class="catalog-control">
      <button type="button" class="catalog-control-trigger" aria-haspopup="menu" :aria-expanded="activeMenu === 'view'" @click="toggle('view')">
        <svg class="grid-icon" aria-hidden="true" viewBox="0 0 24 24"><path d="M4 4h6v7H4zM14 4h6v7h-6zM4 15h6v5H4zM14 15h6v5h-6z" /></svg>
        <span>Rodyti</span>
        <svg class="chevron" aria-hidden="true" viewBox="0 0 12 8"><path d="m1 1 5 5 5-5" /></svg>
      </button>
      <div v-if="activeMenu === 'view'" class="catalog-control-menu view-menu" role="menu">
        <p class="catalog-control-title">Prekės eilėje</p>
        <button v-for="columns in ([3, 4] as const)" :key="columns" type="button" role="menuitemradio" :aria-checked="gridColumns === columns" :class="{ selected: gridColumns === columns }" @click="selectColumns(columns)">
          <span class="grid-preview" :class="`columns-${columns}`"><i v-for="item in columns" :key="item" /></span>
          <span>{{ columns }} prekės</span>
          <svg v-if="gridColumns === columns" class="check-icon" aria-hidden="true" viewBox="0 0 16 16"><path d="m2 8 4 4 8-9" /></svg>
        </button>
      </div>
    </div>

    <div class="catalog-control">
      <button type="button" class="catalog-control-trigger" aria-haspopup="menu" :aria-expanded="activeMenu === 'sort'" @click="toggle('sort')">
        <svg aria-hidden="true" viewBox="0 0 24 24"><path d="M8 4v15m0 0-4-4m4 4 4-4M16 20V5m0 0-4 4m4-4 4 4" /></svg>
        <span>Rūšiuoti</span>
        <svg class="chevron" aria-hidden="true" viewBox="0 0 12 8"><path d="m1 1 5 5 5-5" /></svg>
      </button>
      <div v-if="activeMenu === 'sort'" class="catalog-control-menu sort-menu" role="menu">
        <p class="catalog-control-title">Rūšiuoti pagal</p>
        <button v-for="option in sortOptions" :key="option.value" type="button" role="menuitemradio" :aria-checked="sort === option.value || (!sort && option.value === 'newest')" :class="{ selected: sort === option.value || (!sort && option.value === 'newest') }" @click="selectSort(option.value)">
          <span>{{ option.label }}</span>
          <svg v-if="sort === option.value || (!sort && option.value === 'newest')" class="check-icon" aria-hidden="true" viewBox="0 0 16 16"><path d="m2 8 4 4 8-9" /></svg>
        </button>
        <p class="current-sort">Dabar: {{ currentSort }}</p>
      </div>
    </div>
  </div>
</template>
