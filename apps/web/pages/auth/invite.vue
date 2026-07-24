<script setup lang="ts">
import type { Session } from "@supabase/supabase-js";
const password = ref("");
const repeatedPassword = ref("");
const ready = ref(false);
const pending = ref(false);
const error = ref("");
const status = ref("Tikrinama kvietimo nuoroda…");
const { $supabase } = useNuxtApp();

async function waitForInviteSession() {
  const current = await $supabase.auth.getSession();
  if (current.data.session) return current.data.session;

  return await new Promise((resolve) => {
    let settled = false;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    let subscription: { unsubscribe: () => void } | null = null;
    const finish = (session: Session | null) => {
      if (settled) return;
      settled = true;
      if (timeout) clearTimeout(timeout);
      subscription?.unsubscribe();
      resolve(session);
    };
    const result = $supabase.auth.onAuthStateChange((event, session) => {
      if (event === "SIGNED_IN" || event === "INITIAL_SESSION" || event === "TOKEN_REFRESHED") finish(session);
    });
    subscription = result.data.subscription;
    if (settled) subscription.unsubscribe();
    if (!settled) {
      timeout = setTimeout(async () => {
        const fallback = await $supabase.auth.getSession();
        finish(fallback.data.session);
      }, 10000);
    }
  });
}

onMounted(async () => {
  const url = new URL(location.href);
  const hash = new URLSearchParams(url.hash.replace(/^#/, ""));
  if (hash.get("error") || hash.get("error_code")) {
    error.value = "Kvietimo nuoroda nebegalioja arba jau buvo panaudota.";
    status.value = "";
    return;
  }

  // Invite links from GoTrue use an implicit-flow hash even though the app
  // otherwise uses PKCE. Explicitly install that session before checking it.
  const accessToken = hash.get("access_token");
  const refreshToken = hash.get("refresh_token");
  if (accessToken && refreshToken) {
    const { error: sessionError } = await $supabase.auth.setSession({
      access_token: accessToken,
      refresh_token: refreshToken
    });
    if (sessionError) {
      error.value = "Kvietimo nuoroda nebegalioja arba jau buvo panaudota.";
      status.value = "";
      return;
    }
  }

  // Wait for detectSessionInUrl to finish exchanging the invite URL.
  const session = await waitForInviteSession();
  if (!session) {
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
