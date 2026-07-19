<script setup lang="ts">
import type { AuthError } from "@supabase/supabase-js";

const email = ref("");
const pending = ref(false);
const error = ref("");
const sent = ref(false);
const emailInput = ref<HTMLInputElement | null>(null);
const { $supabase } = useNuxtApp();

function messageFor(authError: AuthError) {
  const message = authError.message.toLowerCase();
  if (authError.status === 429 || message.includes("rate limit")) {
    return "Per daug užklausų. Palaukite kelias minutes ir bandykite dar kartą.";
  }
  return "Laiško išsiųsti nepavyko. Patikrinkite el. paštą ir bandykite dar kartą.";
}

async function sendResetLink() {
  error.value = "";
  if (!emailInput.value?.reportValidity()) return;

  pending.value = true;
  const { error: authError } = await $supabase.auth.resetPasswordForEmail(email.value.trim(), {
    redirectTo: `${location.origin}/auth/reset-password`
  });
  pending.value = false;

  if (authError) {
    error.value = messageFor(authError);
    return;
  }

  // Same response is shown for known and unknown addresses to avoid account enumeration.
  sent.value = true;
}
</script>

<template>
  <main class="auth-page">
    <section class="auth-card" aria-labelledby="forgot-password-title">
      <p class="eyebrow">PASKYROS ATKŪRIMAS</p>
      <h1 id="forgot-password-title">Atkurkite slaptažodį</h1>

      <template v-if="sent">
        <p class="panel-note" role="status">Jei ši paskyra egzistuoja, į {{ email.trim() }} išsiuntėme slaptažodžio atkūrimo nuorodą. Patikrinkite ir šlamšto aplanką.</p>
        <NuxtLink to="/login" class="primary auth-link-button">Grįžti į prisijungimą</NuxtLink>
      </template>

      <template v-else>
        <p class="panel-note">Įveskite paskyros el. paštą. Atsiųsime saugią nuorodą naujam slaptažodžiui nustatyti.</p>
        <form @submit.prevent="sendResetLink">
          <label>
            El. paštas
            <input ref="emailInput" v-model="email" type="email" autocomplete="email" inputmode="email" required>
          </label>
          <button class="primary" :disabled="pending">{{ pending ? "Siunčiama…" : "Siųsti atkūrimo nuorodą" }}</button>
        </form>
        <p v-if="error" class="error" role="alert">{{ error }}</p>
        <NuxtLink to="/login" class="back">Grįžti į prisijungimą</NuxtLink>
      </template>
    </section>
  </main>
</template>

<style scoped>
.auth-link-button { display: block; margin-top: 24px; text-align: center; text-decoration: none; }
.auth-card button:disabled { cursor: not-allowed; opacity: .55; }
</style>
