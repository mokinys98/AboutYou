<script setup lang="ts">
const isMenuOpen = ref(false);
const { user, signOut: authSignOut } = useAuth();
const { isAdmin, loadMember, clearMember } = useMember();

watch(user, (value) => {
  if (value) void loadMember();
  else clearMember();
}, { immediate: true });

async function signOut() {
  closeMenu();
  clearMember();
  await authSignOut();
}

function closeMenu() {
  isMenuOpen.value = false;
}

function toggleMenu() {
  isMenuOpen.value = !isMenuOpen.value;
}

function handleEscape(event: KeyboardEvent) {
  if (event.key === 'Escape') closeMenu();
}

watch(isMenuOpen, (open) => {
  if (!import.meta.client) return;
  document.body.style.overflow = open ? 'hidden' : '';
});

onMounted(() => window.addEventListener('keydown', handleEscape));
onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleEscape);
  if (import.meta.client) document.body.style.overflow = '';
});
</script>

<template>
  <div>
    <header v-if="user" class="site-header">
      <div class="site-header-inner">
        <NuxtLink to="/" class="brand">KAINORAŠTIS</NuxtLink>
        <button
          class="menu-trigger"
          type="button"
          aria-label="Atidaryti meniu"
          :aria-expanded="isMenuOpen"
          aria-controls="site-navigation"
          @click="toggleMenu"
        >
          <span></span>
          <span></span>
          <span></span>
        </button>
        <div v-if="isMenuOpen" class="menu-backdrop" aria-hidden="true" @click="closeMenu"></div>
        <nav id="site-navigation" class="site-navigation" :class="{ open: isMenuOpen }" aria-label="Pagrindinis meniu">
          <div class="mobile-menu-head">
            <span>Meniu</span>
            <button class="menu-close" type="button" aria-label="Uždaryti meniu" @click="closeMenu">×</button>
          </div>
          <NuxtLink to="/" @click="closeMenu">Katalogas</NuxtLink>
          <NuxtLink to="/watchlist" @click="closeMenu">Stebimos prekės</NuxtLink>
          <NuxtLink v-if="isAdmin" to="/admin" @click="closeMenu">Valdymas</NuxtLink>
          <NuxtLink to="/profile" @click="closeMenu">Profilis</NuxtLink>
          <button class="link-button" @click="signOut">Atsijungti</button>
        </nav>
      </div>
    </header>
    <NuxtPage />
  </div>
</template>
