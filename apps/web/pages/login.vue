<script setup lang="ts">
const email = ref("");
const sent = ref(false);
const error = ref("");
const loading = ref(false);
const { $supabase } = useNuxtApp();

async function submit() {
  loading.value = true; error.value = "";
  const { error: authError } = await $supabase.auth.signInWithOtp({
    email: email.value,
    options: { shouldCreateUser: false, emailRedirectTo: `${location.origin}/auth/callback` }
  });
  loading.value = false;
  if (authError) error.value = "Prisijungimo nuorodos išsiųsti nepavyko.";
  else sent.value = true;
}
</script>

<template>
  <main class="auth-page">
    <section class="auth-card">
      <p class="eyebrow">PRIVATUS KATALOGAS</p>
      <h1>Prisijunkite prie komandos</h1>
      <p v-if="sent">Nuoroda išsiųsta į <strong>{{ email }}</strong>. Patikrinkite paštą.</p>
      <form v-else @submit.prevent="submit">
        <label>El. paštas<input v-model="email" type="email" autocomplete="email" required></label>
        <button class="primary" :disabled="loading">{{ loading ? "Siunčiama…" : "Siųsti prisijungimo nuorodą" }}</button>
        <p v-if="error" class="error">{{ error }}</p>
      </form>
    </section>
  </main>
</template>

