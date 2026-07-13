<script setup lang="ts">
import { brandTierLabels, type BrandTier } from "@catalog/shared";

const props = defineProps<{ tier: BrandTier | null; compact?: boolean }>();
const visibleTier = computed(() => props.tier && (["S", "A", "B"] as const).includes(props.tier as "S" | "A" | "B") ? props.tier : null);
const label = computed(() => visibleTier.value ? brandTierLabels[visibleTier.value] : "");
</script>

<template>
  <span
    v-if="visibleTier"
    class="brand-tier-ribbon"
    :class="[`tier-${visibleTier.toLowerCase()}`, { compact }]"
    :title="`${visibleTier} tier · ${label}`"
  >
    <span aria-hidden="true">{{ label }}</span>
    <span class="sr-only">Brando lygis {{ visibleTier }} – {{ label }}</span>
  </span>
</template>
