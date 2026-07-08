<script setup lang="ts">
const { user, signOut } = useAuth();
</script>

<template>
  <div>
    <header v-if="user" class="site-header">
      <NuxtLink to="/" class="brand">KAINORAŠTIS</NuxtLink>
      <nav>
        <NuxtLink to="/">Katalogas</NuxtLink>
        <NuxtLink to="/watchlist">Stebimos prekės</NuxtLink>
        <NuxtLink to="/admin">Valdymas</NuxtLink>
        <NuxtLink to="/profile">Profilis</NuxtLink>
        <button class="link-button" @click="signOut">Atsijungti</button>
      </nav>
    </header>
    <NuxtPage />
  </div>
</template>
