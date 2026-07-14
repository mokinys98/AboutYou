<script setup lang="ts">
import type { Alert, ProductAlertConditions, TelegramConnection } from "@catalog/shared";

const { member, memberLoaded, isAdmin, enabled, loadMember, setEnabled } = useProductDebug();
const api = useApi();
const connection = ref<TelegramConnection | null>(null); const alerts = ref<Alert[]>([]);
const loading = ref(true); const pending = ref(""); const error = ref(""); const info = ref("");
const editing = ref<Alert | null>(null); const editName = ref(""); const editPrice = ref("");
const editObserved = ref(true); const editLpl = ref(true); const editReturn = ref(true); const editSizes = ref<string[]>([]);

async function load() {
  loading.value = true; error.value = "";
  try {
    [connection.value, alerts.value] = await Promise.all([
      api<TelegramConnection>("/v1/telegram/connection"), api<Alert[]>("/v1/alerts")
    ]);
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Alertų informacijos gauti nepavyko"; }
  finally { loading.value = false; }
}
async function connectTelegram() {
  pending.value = "connect"; error.value = "";
  try {
    const result = await api<{ url: string }>("/v1/telegram/link", { method: "POST" });
    window.open(result.url, "_blank", "noopener,noreferrer");
    info.value = "Telegram lange paspauskite START, tada čia atnaujinkite būseną.";
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Telegram prijungimo pradėti nepavyko"; }
  finally { pending.value = ""; }
}
async function disconnectTelegram() {
  if (!confirm("Atjungti Telegram? Alertai liks, bet pranešimai nebus siunčiami.")) return;
  pending.value = "disconnect";
  try { await api("/v1/telegram/connection", { method: "DELETE" }); await load(); }
  catch (cause) { error.value = cause instanceof Error ? cause.message : "Telegram atjungti nepavyko"; }
  finally { pending.value = ""; }
}
async function testTelegram() {
  pending.value = "test"; info.value = "";
  try { await api("/v1/telegram/test", { method: "POST" }); info.value = "Testinis pranešimas išsiųstas."; }
  catch (cause) { error.value = cause instanceof Error ? cause.message : "Pranešimo išsiųsti nepavyko"; }
  finally { pending.value = ""; }
}
async function toggleAlert(alert: Alert) {
  pending.value = alert.id;
  try {
    const updated = await api<Alert>(`/v1/alerts/${alert.id}`, { method: "PATCH", body: { enabled: !alert.enabled } });
    alerts.value = alerts.value.map((item) => item.id === updated.id ? updated : item);
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Alerto pakeisti nepavyko"; }
  finally { pending.value = ""; }
}
async function removeAlert(alert: Alert) {
  if (!confirm(alert.kind === "product" ? "Ištrinti alertą ir pašalinti prekę iš stebimų?" : "Ištrinti filtro alertą?")) return;
  pending.value = alert.id;
  try { await api(`/v1/alerts/${alert.id}`, { method: "DELETE" }); alerts.value = alerts.value.filter((item) => item.id !== alert.id); }
  catch (cause) { error.value = cause instanceof Error ? cause.message : "Alerto ištrinti nepavyko"; }
  finally { pending.value = ""; }
}
function edit(alert: Alert) {
  editing.value = alert; editName.value = alert.name;
  if (alert.kind === "product") {
    editPrice.value = alert.conditions.priceBelow === undefined ? "" : String(alert.conditions.priceBelow / 100);
    editObserved.value = alert.conditions.belowObserved30d; editLpl.value = alert.conditions.belowSourceLpl30d;
    editReturn.value = alert.conditions.backInCatalog; editSizes.value = alert.conditions.sizeOptions.map((size) => size.id);
  }
}
async function saveEdit() {
  if (!editing.value) return; pending.value = editing.value.id; error.value = "";
  const body: Record<string, unknown> = { name: editName.value };
  if (editing.value.kind === "product") {
    const cents = editPrice.value.trim() ? Math.round(Number(editPrice.value.replace(",", ".")) * 100) : undefined;
    if (cents !== undefined && (!Number.isFinite(cents) || cents < 0)) { error.value = "Įveskite teisingą kainą"; pending.value = ""; return; }
    const conditions: ProductAlertConditions = {
      ...(cents === undefined ? {} : { priceBelow: cents }), belowObserved30d: editObserved.value,
      belowSourceLpl30d: editLpl.value, backInCatalog: editReturn.value,
      sizeOptions: editing.value.conditions.sizeOptions.filter((size) => editSizes.value.includes(size.id))
    };
    body.conditions = conditions;
  }
  try {
    const updated = await api<Alert>(`/v1/alerts/${editing.value.id}`, { method: "PATCH", body });
    alerts.value = alerts.value.map((item) => item.id === updated.id ? updated : item); editing.value = null;
  } catch (cause) { error.value = cause instanceof Error ? cause.message : "Alerto išsaugoti nepavyko"; }
  finally { pending.value = ""; }
}
function summary(alert: Alert) {
  if (alert.kind === "filter") return "Naujos prekės pagal išsaugotus katalogo filtrus";
  const items = [] as string[];
  if (alert.conditions.priceBelow !== undefined) items.push(`kaina ≤ ${(alert.conditions.priceBelow / 100).toFixed(2)} €`);
  if (alert.conditions.belowObserved30d) items.push("30 d. minimumas");
  if (alert.conditions.belowSourceLpl30d) items.push("≤ LPL");
  if (alert.conditions.backInCatalog) items.push("sugrįžimas");
  if (alert.conditions.sizeOptions.length) items.push(`dydžiai: ${alert.conditions.sizeOptions.map((size) => size.label).join(", ")}`);
  return items.join(" · ");
}
const formatDate = (value: string | null) => value ? new Intl.DateTimeFormat("lt-LT", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "Dar nesuveikė";

onMounted(() => { void loadMember(true); void load(); });
</script>

<template>
  <main class="profile-page">
    <header class="page-title"><p class="eyebrow">PASKYRA</p><h1>Profilis</h1></header>
    <p v-if="!memberLoaded">Kraunama…</p><p v-else-if="!member" class="error-state">Profilio informacijos gauti nepavyko.</p>
    <template v-else>
      <dl class="profile-details"><div><dt>El. paštas</dt><dd>{{ member.email }}</dd></div><div><dt>Rolė</dt><dd>{{ member.role }}</dd></div></dl>
      <section class="profile-setting telegram-setting">
        <div><p class="eyebrow">PRANEŠIMAI</p><h2>Telegram</h2><p v-if="connection?.connected">Prijungta <template v-if="connection.username">kaip @{{ connection.username }}</template>.</p><p v-else>Prijunkite botą, kad alertus gautumėte į privatų Telegram pokalbį.</p><p v-if="connection?.lastError" class="error">{{ connection.lastError }}</p></div>
        <div class="profile-actions"><template v-if="connection?.connected"><button :disabled="pending === 'test'" @click="testTelegram">Siųsti testą</button><button :disabled="pending === 'disconnect'" @click="disconnectTelegram">Atjungti</button></template><button v-else class="primary" :disabled="pending === 'connect'" @click="connectTelegram">Prijungti Telegram</button><button type="button" @click="load">Atnaujinti būseną</button></div>
      </section>
      <p v-if="info" class="success-state">{{ info }}</p><p v-if="error" class="error-state">{{ error }}</p>

      <section id="alerts" class="profile-alerts">
        <div class="section-heading"><div><p class="eyebrow">AUTOMATIKA</p><h2>Mano alertai</h2></div><span>{{ alerts.length }}</span></div>
        <p v-if="loading">Kraunama…</p>
        <div v-else-if="alerts.length" class="alert-list">
          <article v-for="alert in alerts" :key="alert.id" class="alert-row" :class="{ disabled: !alert.enabled }">
            <img v-if="alert.kind === 'product' && alert.product.imageUrl" :src="alert.product.imageUrl" :alt="alert.product.name">
            <div class="alert-row-copy"><span class="alert-kind">{{ alert.kind === "product" ? "PREKĖ" : "FILTRAS" }}</span><h3>{{ alert.name }}</h3><p>{{ summary(alert) }}</p><small>Paskutinis pranešimas: {{ formatDate(alert.lastTriggeredAt) }}</small><small v-if="alert.lastDeliveryError" class="error">{{ alert.lastDeliveryError }}</small></div>
            <div class="alert-row-actions"><label class="debug-toggle"><input type="checkbox" :checked="alert.enabled" :disabled="pending === alert.id" @change="toggleAlert(alert)"><span>{{ alert.enabled ? "Įjungtas" : "Išjungtas" }}</span></label><button @click="edit(alert)">Redaguoti</button><button class="danger" @click="removeAlert(alert)">Ištrinti</button></div>
          </article>
        </div>
        <div v-else class="empty-state"><h3>Alertų dar nėra</h3><p>Kataloge pasirinkite filtrus ir paspauskite varpelį arba pamėkite prekę.</p><NuxtLink to="/" class="primary empty-action">Atidaryti katalogą</NuxtLink></div>
      </section>

      <section v-if="isAdmin" class="profile-setting"><div><h2>Produkto debug režimas</h2><p>Produkto kortelėse parodo nuorodą į normalizuotus ir pilnus sanitizuotus API duomenis.</p></div><label class="debug-toggle"><input type="checkbox" :checked="enabled" @change="setEnabled(($event.target as HTMLInputElement).checked)"><span>{{ enabled ? "Įjungtas" : "Išjungtas" }}</span></label></section>
    </template>

    <Teleport to="body"><div v-if="editing" class="modal-backdrop" @click.self="editing = null"><section class="alert-dialog" role="dialog" aria-modal="true"><button class="dialog-close" @click="editing = null">×</button><p class="eyebrow">REDAGUOTI ALERTĄ</p><h2>{{ editing.name }}</h2><form @submit.prevent="saveEdit"><label class="field">Pavadinimas<input v-model="editName" required maxlength="120"></label><template v-if="editing.kind === 'product'"><label class="field">Kainos riba<input v-model="editPrice" inputmode="decimal" placeholder="Nebūtina"></label><label class="check alert-check"><input v-model="editObserved" type="checkbox"> Naujas 30 d. minimumas</label><label class="check alert-check"><input v-model="editLpl" type="checkbox"> Kaina ≤ LPL</label><label class="check alert-check"><input v-model="editReturn" type="checkbox"> Sugrįžimas į katalogą</label><fieldset v-if="editing.conditions.sizeOptions.length" class="alert-sizes"><legend>Stebimi dydžiai</legend><label v-for="size in editing.conditions.sizeOptions" :key="size.id" class="check"><input v-model="editSizes" type="checkbox" :value="size.id"> {{ size.label }}</label></fieldset></template><p v-else>Norėdami pakeisti filtro sudėtį, atidarykite katalogą su norimais filtrais ir sukurkite naują alertą.</p><div class="dialog-actions"><button type="button" @click="editing = null">Atšaukti</button><button class="primary" :disabled="pending === editing.id">Išsaugoti</button></div></form></section></div></Teleport>
  </main>
</template>
