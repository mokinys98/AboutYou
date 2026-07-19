<script setup lang="ts">
import type { AuthError } from "@supabase/supabase-js";

const email = ref("");
const password = ref("");
const activeAction = ref<"password" | "magic" | null>(null);
const error = ref("");
const status = ref("");
const cooldown = ref(0);
const emailInput = ref<HTMLInputElement | null>(null);
const { $supabase } = useNuxtApp();

let cooldownTimer: ReturnType<typeof setInterval> | undefined;

onMounted(() => {
  if (useRoute().query.reset === "success") {
    status.value = "Slaptažodis pakeistas. Dabar galite prisijungti su naujuoju slaptažodžiu.";
  }
});

function clearMessages() {
  error.value = "";
  status.value = "";
}

function messageFor(authError: AuthError, action: "password" | "magic") {
  const message = authError.message.toLowerCase();

  if (message.includes("invalid login credentials")) {
    return "Neteisingas el. paštas arba slaptažodis.";
  }
  if (authError.status === 429 || message.includes("rate limit")) {
    return "Viršytas prisijungimo laiškų limitas. Palaukite ir bandykite vėliau.";
  }
  if (message.includes("email address not authorized")) {
    return "Šiam el. paštui neleidžiama gauti prisijungimo nuorodos.";
  }

  return action === "password"
    ? "Prisijungti nepavyko. Patikrinkite duomenis ir bandykite dar kartą."
    : "Prisijungimo nuorodos išsiųsti nepavyko.";
}

function startCooldown() {
  cooldown.value = 60;
  if (cooldownTimer) clearInterval(cooldownTimer);
  cooldownTimer = setInterval(() => {
    cooldown.value -= 1;
    if (cooldown.value <= 0 && cooldownTimer) {
      clearInterval(cooldownTimer);
      cooldownTimer = undefined;
    }
  }, 1000);
}

async function signInWithPassword() {
  clearMessages();
  activeAction.value = "password";

  const { error: authError } = await $supabase.auth.signInWithPassword({
    email: email.value.trim(),
    password: password.value
  });

  activeAction.value = null;
  if (authError) {
    error.value = messageFor(authError, "password");
    return;
  }

  await navigateTo("/");
}

async function sendMagicLink() {
  clearMessages();
  if (!emailInput.value?.reportValidity()) return;

  activeAction.value = "magic";
  const { error: authError } = await $supabase.auth.signInWithOtp({
    email: email.value.trim(),
    options: {
      shouldCreateUser: false,
      emailRedirectTo: `${location.origin}/auth/callback`
    }
  });

  activeAction.value = null;
  if (authError) {
    error.value = messageFor(authError, "magic");
    return;
  }

  status.value = `Prisijungimo nuoroda išsiųsta į ${email.value.trim()}.`;
  startCooldown();
}

onBeforeUnmount(() => {
  if (cooldownTimer) clearInterval(cooldownTimer);
});
</script>

<template>
  <main class="login-page">
    <section class="login-intro" aria-labelledby="login-intro-title">
      <p class="login-brand">KAINORAŠTIS</p>
      <div class="login-intro-copy">
        <p class="eyebrow">PRIVATUS KATALOGAS</p>
        <h1 id="login-intro-title">Kainos, kurias verta stebėti.</h1>
        <p>Atrinkti ABOUT YOU produktai, kainų istorija ir komandos įrankiai vienoje vietoje.</p>
      </div>
      <p class="login-intro-note">Tik patvirtintiems komandos nariams.</p>
    </section>

    <section class="login-panel" aria-labelledby="login-title">
      <div class="login-card">
        <p class="eyebrow">KOMANDOS PRIEIGA</p>
        <h2 id="login-title">Prisijunkite</h2>
        <p class="login-lead">Naudokite savo Supabase naudotojo duomenis.</p>

        <form class="login-form" @submit.prevent="signInWithPassword">
          <label class="login-field">
            <span>El. paštas</span>
            <input
              ref="emailInput"
              v-model="email"
              type="email"
              autocomplete="email"
              inputmode="email"
              placeholder="vardas@komanda.lt"
              required
            >
          </label>

          <label class="login-field">
            <span>Slaptažodis</span>
            <input
              v-model="password"
              type="password"
              autocomplete="current-password"
              placeholder="Įveskite slaptažodį"
              required
            >
          </label>

          <button class="primary login-submit" :disabled="activeAction !== null">
            {{ activeAction === "password" ? "Jungiamasi…" : "Prisijungti" }}
          </button>
        </form>

        <NuxtLink class="login-forgot" to="/auth/forgot-password">Pamiršote slaptažodį?</NuxtLink>

        <div class="login-divider" aria-hidden="true"><span>arba</span></div>

        <div class="login-magic">
          <div>
            <h3>Supabase magic link</h3>
            <p>Vienkartinę nuorodą išsiųsime į aukščiau nurodytą el. paštą.</p>
          </div>
          <button
            type="button"
            class="secondary login-magic-button"
            :disabled="activeAction !== null || cooldown > 0 || !email.trim()"
            @click="sendMagicLink"
          >
            <template v-if="activeAction === 'magic'">Siunčiama…</template>
            <template v-else-if="cooldown > 0">Siųsti dar kartą po {{ cooldown }} s</template>
            <template v-else>Gauti magic link</template>
          </button>
        </div>

        <p v-if="error" class="login-message error" role="alert" aria-live="assertive">{{ error }}</p>
        <p v-if="status" class="login-message login-success" role="status" aria-live="polite">{{ status }}</p>
        <p class="login-security">Jūsų prisijungimą saugiai tvarko Supabase.</p>
      </div>
    </section>
  </main>
</template>

<style scoped>
.login-page {
  min-height: 100vh;
  display: grid;
  grid-template-columns: minmax(0, 1.05fr) minmax(520px, .95fr);
  background: #fff;
}

.login-intro {
  min-height: 100vh;
  padding: clamp(32px, 4.5vw, 72px);
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  overflow: hidden;
  background: var(--ink);
  color: #fff;
}

.login-brand {
  margin: 0;
  font-size: 17px;
  font-weight: 900;
  letter-spacing: .18em;
}

.login-intro-copy { max-width: 660px; }
.login-intro-copy .eyebrow { color: var(--accent); }

.login-intro-copy h1 {
  margin: 20px 0 28px;
  font-size: clamp(52px, 6.2vw, 96px);
  line-height: .91;
  letter-spacing: -.065em;
}

.login-intro-copy > p:last-child {
  max-width: 520px;
  margin: 0;
  color: #b8b8b8;
  font-size: 17px;
  line-height: 1.55;
}

.login-intro-note {
  margin: 0;
  color: #8b8b8b;
  font-size: 12px;
}

.login-panel {
  display: grid;
  place-items: center;
  padding: 48px;
  background: var(--surface);
}

.login-card {
  width: min(480px, 100%);
  padding: clamp(32px, 4vw, 52px);
  border: 1px solid var(--line);
  background: #fff;
}

.login-card h2 {
  margin: 12px 0 16px;
  font-size: clamp(38px, 4vw, 54px);
  line-height: .95;
  letter-spacing: -.05em;
}

.login-lead {
  margin: 0 0 30px;
  color: var(--muted);
  font-size: 14px;
  line-height: 1.55;
}

.login-form { display: grid; gap: 18px; }

.login-field {
  display: grid;
  gap: 8px;
  font-size: 12px;
  font-weight: 700;
}

.login-field input {
  width: 100%;
  height: 50px;
  padding: 0 15px;
  border: 1px solid var(--line);
  border-radius: 0;
  outline: none;
  background: #fff;
  color: var(--ink);
  font: inherit;
  font-size: 14px;
  transition: border-color .15s, box-shadow .15s;
}

.login-field input::placeholder { color: #999; }
.login-field input:focus { border-color: var(--ink); box-shadow: 0 0 0 2px #1112; }
.login-submit, .login-magic-button { width: 100%; min-height: 50px; }
.login-submit { margin-top: 4px; }
.login-forgot {
  display: block;
  margin-top: 14px;
  color: var(--muted);
  font-size: 12px;
  text-align: right;
}
.login-forgot:hover { color: var(--ink); }
.login-card button:disabled { cursor: not-allowed; opacity: .48; }
.login-card button:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }

.login-divider {
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  align-items: center;
  gap: 14px;
  margin: 28px 0;
  color: var(--muted);
  font-size: 11px;
  letter-spacing: .12em;
  text-transform: uppercase;
}

.login-divider::before, .login-divider::after { content: ""; height: 1px; background: var(--line); }
.login-magic { display: grid; gap: 16px; }
.login-magic h3 { margin: 0 0 6px; font-size: 14px; }
.login-magic p { margin: 0; color: var(--muted); font-size: 12px; line-height: 1.5; }
.login-magic-button { background: #fff; }

.login-message {
  margin: 20px 0 0;
  padding: 10px 12px;
  border-left: 3px solid currentColor;
  background: #f8f8f6;
  font-size: 12px;
  line-height: 1.5;
}

.login-success { color: #216e39; background: #edf8ef; }

.login-security {
  margin: 28px 0 0;
  padding-top: 20px;
  border-top: 1px solid var(--line);
  color: var(--muted);
  font-size: 11px;
}

@media (max-width: 900px) {
  .login-page { grid-template-columns: 1fr; }
  .login-intro { min-height: auto; padding: 30px 24px 38px; gap: 48px; }
  .login-intro-copy { max-width: 580px; }
  .login-intro-copy h1 { margin: 16px 0 20px; font-size: clamp(44px, 12vw, 72px); }
  .login-intro-note { display: none; }
  .login-panel { padding: 24px; }
}

@media (max-width: 480px) {
  .login-intro { padding: 24px 18px 32px; gap: 34px; }
  .login-brand { font-size: 14px; }
  .login-intro-copy h1 { font-size: 43px; }
  .login-intro-copy > p:last-child { font-size: 14px; }
  .login-panel { padding: 0; background: #fff; }
  .login-card { padding: 34px 18px 40px; border: 0; }
  .login-card h2 { font-size: 40px; }
}
</style>
