<script setup lang="ts">
const message = ref("Tikrinama prisijungimo nuoroda…");
onMounted(async () => {
  const { $supabase } = useNuxtApp();
  // detectSessionInUrl in the Supabase client handles the PKCE code once.
  const { data } = await $supabase.auth.getSession();
  if (data.session) await navigateTo("/"); else message.value = "Prisijungti nepavyko.";
});
</script>

<template><main class="auth-page"><section class="auth-card"><h1>{{ message }}</h1></section></main></template>
