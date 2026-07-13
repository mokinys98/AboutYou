<script setup lang="ts">
const { user, signOut: authSignOut } = useAuth();
const { isAdmin, loadMember, clearMember } = useMember();

watch(user, (value) => {
  if (value) void loadMember();
  else clearMember();
}, { immediate: true });

async function signOut() {
  clearMember();
  await authSignOut();
}
</script>

<template>
  <div>
    <header v-if="user" class="site-header">
      <div class="site-header-inner">
        <NuxtLink to="/" class="brand">KAINORAŠTIS</NuxtLink>
        <nav>
          <NuxtLink to="/">Katalogas</NuxtLink>
          <NuxtLink to="/watchlist">Stebimos prekės</NuxtLink>
          <NuxtLink v-if="isAdmin" to="/admin">Valdymas</NuxtLink>
          <NuxtLink to="/profile">Profilis</NuxtLink>
          <button class="link-button" @click="signOut">Atsijungti</button>
        </nav>
      </div>
    </header>
    <NuxtPage />
  </div>
</template>
