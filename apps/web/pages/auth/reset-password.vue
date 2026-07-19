<script setup lang="ts">
const password = ref("");
const repeatedPassword = ref("");
const ready = ref(false);
const pending = ref(false);
const error = ref("");
const status = ref("Tikrinama slaptažodžio atkūrimo nuoroda…");
const { $supabase } = useNuxtApp();

onMounted(async () => {
  const url = new URL(location.href);
  const hash = new URLSearchParams(url.hash.replace(/^#/, ""));
  if (hash.get("error") || hash.get("error_code")) {
    error.value = "Atkūrimo nuoroda nebegalioja arba jau buvo panaudota.";
    status.value = "";
    return;
  }

  // The client plugin has detectSessionInUrl enabled and exchanges the PKCE
  // code during initialization. Do not exchange it a second time here.
  const { data } = await $supabase.auth.getSession();
  if (!data.session) {
    error.value = "Atkūrimo nuoroda nebegalioja arba jau buvo panaudota.";
    status.value = "";
    return;
  }
  ready.value = true;
  status.value = "";
});

async function updatePassword() {
  error.value = "";
  if (password.value.length < 8) {
    error.value = "Slaptažodį turi sudaryti bent 8 simboliai.";
    return;
  }
  if (password.value !== repeatedPassword.value) {
    error.value = "Slaptažodžiai nesutampa.";
    return;
  }

  pending.value = true;
  const { error: passwordError } = await $supabase.auth.updateUser({ password: password.value });
  pending.value = false;
  if (passwordError) {
    error.value = passwordError.message.toLowerCase().includes("weak")
      ? "Pasirinkite stipresnį slaptažodį."
      : "Slaptažodžio išsaugoti nepavyko. Paprašykite naujos atkūrimo nuorodos.";
    return;
  }

  await $supabase.auth.signOut();
  await navigateTo("/login?reset=success");
}
</script>

<template>
  <main class="auth-page">
    <section class="auth-card" aria-labelledby="reset-password-title">
      <p class="eyebrow">PASKYROS ATKŪRIMAS</p>
      <h1 id="reset-password-title">Nustatykite naują slaptažodį</h1>
      <p v-if="status" class="panel-note">{{ status }}</p>
      <p v-if="error" class="error" role="alert">{{ error }}</p>
      <form v-if="ready" @submit.prevent="updatePassword">
        <label>Slaptažodis<input v-model="password" type="password" minlength="8" autocomplete="new-password" required></label>
        <label>Pakartokite slaptažodį<input v-model="repeatedPassword" type="password" minlength="8" autocomplete="new-password" required></label>
        <button class="primary" :disabled="pending">{{ pending ? "Saugoma…" : "Išsaugoti naują slaptažodį" }}</button>
      </form>
      <NuxtLink v-if="error && !ready" to="/auth/forgot-password" class="back">Prašyti naujos nuorodos</NuxtLink>
    </section>
  </main>
</template>

<style scoped>
.auth-card button:disabled { cursor: not-allowed; opacity: .55; }
</style>
