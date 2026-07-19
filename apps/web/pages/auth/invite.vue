<script setup lang="ts">
const password = ref("");
const repeatedPassword = ref("");
const ready = ref(false);
const pending = ref(false);
const error = ref("");
const status = ref("Tikrinama kvietimo nuoroda…");
const { $supabase } = useNuxtApp();

onMounted(async () => {
  const url = new URL(location.href);
  const hash = new URLSearchParams(url.hash.replace(/^#/, ""));
  if (hash.get("error") || hash.get("error_code")) {
    error.value = "Kvietimo nuoroda nebegalioja arba jau buvo panaudota.";
    status.value = "";
    return;
  }

  // detectSessionInUrl in the Supabase client handles the PKCE code once.
  const { data } = await $supabase.auth.getSession();
  if (!data.session) {
    error.value = "Kvietimo nuoroda nebegalioja arba jau buvo panaudota.";
    status.value = "";
    return;
  }
  ready.value = true;
  status.value = "";
});

async function setPassword() {
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
  if (passwordError) {
    pending.value = false;
    error.value = passwordError.message.toLowerCase().includes("weak")
      ? "Pasirinkite stipresnį slaptažodį."
      : "Slaptažodžio išsaugoti nepavyko. Bandykite dar kartą.";
    return;
  }

  try {
    const api = useApi();
    await api("/v1/users/accept-invite", { method: "POST" });
  } catch {
    // Password setup succeeded; accepting the invitation is safe to retry later.
  }
  pending.value = false;
  await navigateTo("/");
}
</script>

<template>
  <main class="auth-page">
    <section class="auth-card" aria-labelledby="invite-title">
      <p class="eyebrow">KOMANDOS KVETIMAS</p>
      <h1 id="invite-title">Sukurkite slaptažodį</h1>
      <p v-if="status" class="panel-note">{{ status }}</p>
      <p v-if="error" class="error" role="alert">{{ error }}</p>
      <form v-if="ready" @submit.prevent="setPassword">
        <label>Slaptažodis<input v-model="password" type="password" minlength="8" autocomplete="new-password" required></label>
        <label>Pakartokite slaptažodį<input v-model="repeatedPassword" type="password" minlength="8" autocomplete="new-password" required></label>
        <button class="primary" :disabled="pending">{{ pending ? "Saugoma…" : "Išsaugoti ir prisijungti" }}</button>
      </form>
      <NuxtLink v-if="error && !ready" to="/login" class="back">Grįžti į prisijungimą</NuxtLink>
    </section>
  </main>
</template>
