<script setup lang="ts">
const message = ref("Tikrinama prisijungimo nuoroda…");
onMounted(async () => {
  const { $supabase } = useNuxtApp();
  const code = new URL(location.href).searchParams.get("code");
  if (code) {
    const { error } = await $supabase.auth.exchangeCodeForSession(code);
    if (error) { message.value = "Nuoroda nebegalioja. Paprašykite naujos."; return; }
  }
  const { data } = await $supabase.auth.getSession();
  if (data.session) await navigateTo("/"); else message.value = "Prisijungti nepavyko.";
});
</script>

<template><main class="auth-page"><section class="auth-card"><h1>{{ message }}</h1></section></main></template>

