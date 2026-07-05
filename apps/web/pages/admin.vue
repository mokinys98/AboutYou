<script setup lang="ts">
type TargetKind = "category" | "brand" | "search";
type Target = {
  id: string;
  label: string;
  url: string;
  kind: TargetKind;
  enabled: boolean;
  priority: number;
  last_success_at: string | null;
  last_error: string | null;
};
type Run = { id: string; status: string; started_at: string; products_count: number; error: string | null; sync_targets?: { label: string } };

const api = useApi();
const targets = ref<Target[]>([]);
const runs = ref<Run[]>([]);
const error = ref("");
const pending = ref("");
const editingId = ref<string | null>(null);
const form = reactive({ label: "", url: "", kind: "category" as TargetKind, priority: 100, enabled: true });
const editForm = reactive({ label: "", url: "", kind: "category" as TargetKind, priority: 100, enabled: true });

async function refresh() {
  try {
    [targets.value, runs.value] = await Promise.all([
      api<Target[]>("/v1/sync-targets"),
      api<Run[]>("/v1/sync-runs")
    ]);
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : "Duomenų užkrauti nepavyko";
  }
}

async function runAction(key: string, action: () => Promise<void>) {
  error.value = "";
  pending.value = key;
  try {
    await action();
  } catch (cause) {
    error.value = cause instanceof Error ? cause.message : "Veiksmo atlikti nepavyko";
  } finally {
    pending.value = "";
  }
}

async function add() {
  await runAction("add", async () => {
    await api("/v1/sync-targets", { method: "POST", body: form });
    Object.assign(form, { label: "", url: "", kind: "category", priority: 100, enabled: true });
    await refresh();
  });
}

function startEdit(target: Target) {
  editingId.value = target.id;
  Object.assign(editForm, {
    label: target.label,
    url: target.url,
    kind: target.kind,
    priority: target.priority,
    enabled: target.enabled
  });
}

function cancelEdit() {
  editingId.value = null;
}

async function save(target: Target) {
  await runAction(`save:${target.id}`, async () => {
    await api(`/v1/sync-targets/${target.id}`, { method: "PATCH", body: editForm });
    editingId.value = null;
    await refresh();
  });
}

async function remove(target: Target) {
  if (!window.confirm(`Ištrinti grupę „${target.label}“? Jos sinchronizavimo darbų istorija taip pat bus ištrinta.`)) return;
  await runAction(`delete:${target.id}`, async () => {
    await api(`/v1/sync-targets/${target.id}`, { method: "DELETE" });
    if (editingId.value === target.id) editingId.value = null;
    await refresh();
  });
}

async function toggle(target: Target) {
  await runAction(`toggle:${target.id}`, async () => {
    await api(`/v1/sync-targets/${target.id}`, { method: "PATCH", body: { enabled: !target.enabled } });
    await refresh();
  });
}

async function queue(target: Target) {
  await runAction(`queue:${target.id}`, async () => {
    await api(`/v1/sync-targets/${target.id}/request-sync`, { method: "POST" });
    await refresh();
  });
}

onMounted(refresh);
</script>

<template>
  <main class="admin-page">
    <div class="page-title"><p class="eyebrow">ADMINISTRAVIMAS</p><h1>Sinchronizavimo grupės</h1></div>
    <p v-if="error" class="error-state">{{ error }}</p>

    <section class="admin-panel">
      <h2>Pridėti grupę</h2>
      <form class="target-form" @submit.prevent="add">
        <label>Pavadinimas<input v-model="form.label" required></label>
        <label>Tipas<select v-model="form.kind"><option value="category">Kategorija</option><option value="brand">Brandas</option><option value="search">Paieška</option></select></label>
        <label>Prioritetas<input v-model.number="form.priority" type="number" min="0" max="1000" required></label>
        <label class="wide">ABOUT YOU URL<input v-model="form.url" type="url" required placeholder="https://www.aboutyou.lt/c/..."></label>
        <button class="primary" :disabled="pending === 'add'">{{ pending === "add" ? "Pridedama…" : "Pridėti" }}</button>
      </form>
    </section>

    <section class="admin-panel">
      <h2>Aktyvios grupės</h2>
      <div class="table-wrap">
        <table>
          <thead><tr><th>Grupė</th><th>Būsena</th><th>Paskutinis atnaujinimas</th><th>Veiksmai</th></tr></thead>
          <tbody>
            <template v-for="target in targets" :key="target.id">
              <tr>
                <td><strong>{{ target.label }}</strong><small>{{ target.url }}</small><small>Prioritetas: {{ target.priority }}</small></td>
                <td><span class="status" :class="target.enabled ? 'success' : ''">{{ target.enabled ? "Aktyvi" : "Išjungta" }}</span><small v-if="target.last_error" class="error">{{ target.last_error }}</small></td>
                <td>{{ target.last_success_at ? new Date(target.last_success_at).toLocaleString("lt-LT") : "—" }}</td>
                <td><div class="row-actions">
                  <button type="button" class="text-action" :disabled="Boolean(pending)" @click="queue(target)">Į eilę</button>
                  <button type="button" class="text-action" :disabled="Boolean(pending)" @click="toggle(target)">{{ target.enabled ? "Išjungti" : "Įjungti" }}</button>
                  <button type="button" class="text-action" :disabled="Boolean(pending)" @click="startEdit(target)">Redaguoti</button>
                  <button type="button" class="text-action danger-action" :disabled="Boolean(pending)" @click="remove(target)">Ištrinti</button>
                </div></td>
              </tr>
              <tr v-if="editingId === target.id" class="target-edit-row">
                <td colspan="4">
                  <form class="target-edit-form" @submit.prevent="save(target)">
                    <label>Pavadinimas<input v-model="editForm.label" required></label>
                    <label>Tipas<select v-model="editForm.kind"><option value="category">Kategorija</option><option value="brand">Brandas</option><option value="search">Paieška</option></select></label>
                    <label>Prioritetas<input v-model.number="editForm.priority" type="number" min="0" max="1000" required></label>
                    <label class="edit-url">ABOUT YOU URL<input v-model="editForm.url" type="url" required></label>
                    <label class="edit-enabled"><input v-model="editForm.enabled" type="checkbox"> Aktyvi</label>
                    <div class="edit-actions"><button type="submit" class="primary" :disabled="Boolean(pending)">{{ pending === `save:${target.id}` ? "Saugoma…" : "Išsaugoti" }}</button><button type="button" class="secondary" :disabled="Boolean(pending)" @click="cancelEdit">Atšaukti</button></div>
                  </form>
                </td>
              </tr>
            </template>
          </tbody>
        </table>
      </div>
    </section>

    <section class="admin-panel">
      <h2>Paskutiniai darbai</h2>
      <div class="run-list"><div v-for="run in runs.slice(0, 20)" :key="run.id"><span class="status" :class="run.status">{{ run.status }}</span><strong>{{ run.sync_targets?.label }}</strong><time>{{ new Date(run.started_at).toLocaleString("lt-LT") }}</time><span>{{ run.products_count }} produktų</span></div></div>
    </section>
  </main>
</template>
