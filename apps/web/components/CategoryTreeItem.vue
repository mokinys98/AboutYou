<script setup lang="ts">
import type { CatalogCategoryNode } from "@catalog/shared";

const props = defineProps<{ node: CatalogCategoryNode; selectedPath?: string; depth?: number }>();
const emit = defineEmits<{ select: [path: string] }>();
const open = ref(false);
const depth = computed(() => props.depth ?? 0);
const selected = computed(() => props.selectedPath === props.node.path);
const containsSelection = computed(() => Boolean(props.selectedPath && (
  props.selectedPath === props.node.path || props.selectedPath.startsWith(`${props.node.path}>`)
)));

watch(containsSelection, (value) => { if (value) open.value = true; }, { immediate: true });

function select() {
  if (props.node.children.length) open.value = true;
  emit("select", props.node.path);
}
</script>

<template>
  <div class="category-tree-item">
    <div class="category-tree-row" :class="`level-${node.level}`" :style="{ '--category-depth': depth }">
      <button type="button" class="category-tree-select" :class="{ active: selected }" @click="select">
        <span>{{ node.name }}</span><small>{{ node.count }}</small>
      </button>
      <button v-if="node.children.length" type="button" class="category-tree-toggle" :aria-label="`${open ? 'Suskleisti' : 'Išskleisti'} ${node.name}`" :aria-expanded="open" @click="open = !open">⌄</button>
    </div>
    <div v-if="open && node.children.length" class="category-tree-children">
      <CategoryTreeItem v-for="child in node.children" :key="child.id" :node="child" :selected-path="selectedPath" :depth="depth + 1" @select="emit('select', $event)" />
    </div>
  </div>
</template>
