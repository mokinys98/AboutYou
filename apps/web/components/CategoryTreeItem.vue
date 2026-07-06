<script setup lang="ts">
import type { CatalogCategoryNode } from "@catalog/shared";

const props = defineProps<{ node: CatalogCategoryNode; selectedPath?: string; depth?: number; expanded?: boolean }>();
const emit = defineEmits<{ select: [path: string]; expand: [path: string | null] }>();
const depth = computed(() => props.depth ?? 0);
const selected = computed(() => props.selectedPath === props.node.path);
const open = computed(() => Boolean(props.node.children.length && props.expanded));
const expandedChildPath = ref<string | null>(null);

watch(() => props.selectedPath, (path) => {
  const selectedChild = path
    ? props.node.children.find((child) => path === child.path || path.startsWith(`${child.path}>`))
    : null;
  expandedChildPath.value = selectedChild?.path ?? null;
}, { immediate: true });

function select() {
  if (props.node.children.length) emit("expand", props.node.path);
  emit("select", props.node.path);
}

function setExpandedChild(path: string | null) {
  expandedChildPath.value = path;
}
</script>

<template>
  <div class="category-tree-item">
    <div class="category-tree-row" :class="`level-${node.level}`" :style="{ '--category-depth': depth }">
      <button type="button" class="category-tree-select" :class="{ active: selected }" :aria-expanded="node.children.length ? open : undefined" @click="select">
        <span>{{ node.name }}</span><small>{{ node.count }}</small>
      </button>
    </div>
    <div v-if="open && node.children.length" class="category-tree-children">
      <CategoryTreeItem v-for="child in node.children" :key="child.id" :node="child" :selected-path="selectedPath" :depth="depth + 1" :expanded="expandedChildPath === child.path" @select="emit('select', $event)" @expand="setExpandedChild" />
    </div>
  </div>
</template>
