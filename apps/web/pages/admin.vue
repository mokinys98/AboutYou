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
type DashboardCategory = { id: string; parentId: string | null; name: string; level: number; path: string; count: number };
type DashboardRun = Run & { finished_at?: string | null };
type DashboardStats = {
  generatedAt: string;
  parserVersion: number;
  totals: {
    products: number;
    activeProducts: number;
    catalogProducts: number;
    metadataProducts: number;
    premiumProducts: number;
    newProducts: number;
    belowObservedProducts: number;
    enabledTargets: number;
    disabledTargets: number;
  };
  metadata: {
    active?: number;
    complete?: number;
    pending?: number;
    retryable?: number;
    blockedSchema?: number;
    sourceUnavailable?: number;
  };
  categories: DashboardCategory[];
  latestRuns: DashboardRun[];
};

const api = useApi();
const activeTab = ref<"dashboard" | "sync">("dashboard");
const categoryLevel = ref(2);
const dashboard = ref<DashboardStats | null>(null);
const targets = ref<Target[]>([]);
const runs = ref<Run[]>([]);
const error = ref("");
const pending = ref("");
const editingId = ref<string | null>(null);
const form = reactive({ label: "", url: "", kind: "category" as TargetKind, priority: 100, enabled: true });
const editForm = reactive({ label: "", url: "", kind: "category" as TargetKind, priority: 100, enabled: true });

const metadataCoverage = computed(() => pct(dashboard.value?.metadata.complete ?? 0, dashboard.value?.metadata.active ?? dashboard.value?.totals.activeProducts ?? 0));
const productFill = computed(() => pct(dashboard.value?.totals.catalogProducts ?? 0, dashboard.value?.totals.products ?? 0));
const categoryLevels = computed(() => {
  const levels = [...new Set((dashboard.value?.categories ?? []).map((category) => category.level))].sort((a, b) => a - b);
  return levels.length ? levels : [2];
});
const selectedLevelCategories = computed(() => (dashboard.value?.categories ?? []).filter((category) => category.level === categoryLevel.value));
const topCategories = computed(() => [...selectedLevelCategories.value].sort((a, b) => b.count - a.count).slice(0, 10));
const categoryBarMax = computed(() => Math.max(...topCategories.value.map((category) => category.count), 0));
const metadataRows = computed(() => {
  const metadata = dashboard.value?.metadata ?? {};
  const active = metadata.active ?? dashboard.value?.totals.activeProducts ?? 0;
  return [
    { label: "Užkrauta", value: metadata.complete ?? 0, className: "success" },
    { label: "Laukia", value: metadata.pending ?? 0, className: "" },
    { label: "Kartoti", value: metadata.retryable ?? 0, className: "warning" },
    { label: "Schema blokuoja", value: metadata.blockedSchema ?? 0, className: "failed" },
    { label: "Nebepasiekiama", value: metadata.sourceUnavailable ?? 0, className: "muted" }
  ].map((row) => ({ ...row, percent: pct(row.value, active) }));
});

async function refresh() {
  try {
    [dashboard.value, targets.value, runs.value] = await Promise.all([
      api<DashboardStats>("/v1/admin/dashboard"),
      api<Target[]>("/v1/sync-targets"),
      api<Run[]>("/v1/sync-runs")
    ]);
    if (!categoryLevels.value.includes(categoryLevel.value)) categoryLevel.value = categoryLevels.value[0] ?? 2;
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

function pct(value: number, total: number) {
  return total > 0 ? Math.round((value / total) * 100) : 0;
}

function formatNumber(value?: number) {
  return (value ?? 0).toLocaleString("lt-LT");
}

function formatPct(value: number) {
  return `${value.toLocaleString("lt-LT")}%`;
}

function runDuration(run: DashboardRun) {
  if (!run.finished_at) return "vyksta";
  const seconds = Math.max(0, Math.round((new Date(run.finished_at).getTime() - new Date(run.started_at).getTime()) / 1000));
  if (seconds < 60) return `${seconds} s`;
  return `${Math.round(seconds / 60)} min`;
}

onMounted(refresh);
</script>

<template>
  <main class="admin-page">
    <div class="page-title"><p class="eyebrow">ADMINISTRAVIMAS</p><h1>Valdymas</h1></div>
    <p v-if="error" class="error-state">{{ error }}</p>

    <nav class="admin-tabs" aria-label="Valdymo skyriai">
      <button type="button" :class="{ active: activeTab === 'dashboard' }" @click="activeTab = 'dashboard'">Dashboard</button>
      <button type="button" :class="{ active: activeTab === 'sync' }" @click="activeTab = 'sync'">Sinchronizavimas</button>
    </nav>

    <section v-if="activeTab === 'dashboard'" class="admin-dashboard">
      <div class="dashboard-summary">
        <article>
          <span>Visos prekės</span>
          <strong>{{ formatNumber(dashboard?.totals.products) }}</strong>
          <small>{{ formatNumber(dashboard?.totals.activeProducts) }} aktyvių</small>
        </article>
        <article>
          <span>Kataloge</span>
          <strong>{{ formatNumber(dashboard?.totals.catalogProducts) }}</strong>
          <small>{{ formatPct(productFill) }} nuo visų prekių</small>
        </article>
        <article>
          <span>Metaduomenys</span>
          <strong>{{ formatPct(metadataCoverage) }}</strong>
          <small>{{ formatNumber(dashboard?.totals.metadataProducts) }} prekių su metadata</small>
        </article>
        <article>
          <span>Kategorijos</span>
          <strong>{{ formatNumber(dashboard?.categories.length) }}</strong>
          <small>aktyvios medžio šakos</small>
        </article>
      </div>

      <div class="dashboard-grid">
        <section class="admin-panel dashboard-panel">
          <h2>Prekės pagal kategorijas</h2>
          <div class="dashboard-panel-head">
            <p class="panel-note">Lyginamas tik vienas kategorijų medžio lygis.</p>
            <div class="category-level-tabs" aria-label="Kategorijų lygis">
              <button v-for="level in categoryLevels" :key="level" type="button" :class="{ active: categoryLevel === level }" @click="categoryLevel = level">{{ level }} lygis</button>
            </div>
          </div>
          <div class="category-bars">
            <div v-for="category in topCategories" :key="category.path">
              <span>{{ category.name }}</span>
              <i><b :style="{ width: `${pct(category.count, categoryBarMax)}%` }"></b></i>
              <strong>{{ formatNumber(category.count) }}</strong>
            </div>
            <p v-if="!topCategories.length" class="panel-note">Šiame lygyje kategorijų nėra.</p>
          </div>
        </section>

        <section class="admin-panel dashboard-panel">
          <h2>Metaduomenų užsipildymas</h2>
          <p class="panel-note">Parserio versija: {{ dashboard?.parserVersion ?? "-" }}</p>
          <div class="metadata-bars">
            <div v-for="row in metadataRows" :key="row.label">
              <div><span>{{ row.label }}</span><strong>{{ formatNumber(row.value) }} · {{ formatPct(row.percent) }}</strong></div>
              <i><b :class="row.className" :style="{ width: `${row.percent}%` }"></b></i>
            </div>
          </div>
        </section>

        <section class="admin-panel dashboard-panel">
          <h2>Papildomi rodikliai</h2>
          <dl class="dashboard-facts">
            <div><dt>Premium prekės</dt><dd>{{ formatNumber(dashboard?.totals.premiumProducts) }}</dd></div>
            <div><dt>Naujos per 30 d.</dt><dd>{{ formatNumber(dashboard?.totals.newProducts) }}</dd></div>
            <div><dt>Žemiau 30 d. minimumo</dt><dd>{{ formatNumber(dashboard?.totals.belowObservedProducts) }}</dd></div>
            <div><dt>Sync grupės</dt><dd>{{ formatNumber(dashboard?.totals.enabledTargets) }} aktyvios / {{ formatNumber(dashboard?.totals.disabledTargets) }} išjungtos</dd></div>
          </dl>
        </section>

        <section class="admin-panel dashboard-panel">
          <h2>Paskutiniai darbai</h2>
          <div class="dashboard-runs">
            <div v-for="run in dashboard?.latestRuns ?? []" :key="run.id">
              <span class="status" :class="run.status">{{ run.status }}</span>
              <strong>{{ run.sync_targets?.label ?? "-" }}</strong>
              <small>{{ new Date(run.started_at).toLocaleString("lt-LT") }} · {{ runDuration(run) }}</small>
              <em>{{ formatNumber(run.products_count) }} produktų</em>
            </div>
          </div>
        </section>
      </div>
    </section>

    <template v-else>
      <section class="admin-panel">
        <h2>Pridėti grupę</h2>
        <form class="target-form" @submit.prevent="add">
          <label>Pavadinimas<input v-model="form.label" required></label>
          <label>Tipas<select v-model="form.kind"><option value="category">Kategorija</option><option value="brand">Brandas</option><option value="search">Paieška</option></select></label>
          <label>Prioritetas<input v-model.number="form.priority" type="number" min="0" max="1000" required></label>
          <label class="wide">ABOUT YOU URL<input v-model="form.url" type="url" required placeholder="https://www.aboutyou.lt/c/..."></label>
          <button class="primary" :disabled="pending === 'add'">{{ pending === "add" ? "Pridedama..." : "Pridėti" }}</button>
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
                  <td>{{ target.last_success_at ? new Date(target.last_success_at).toLocaleString("lt-LT") : "-" }}</td>
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
                      <div class="edit-actions"><button type="submit" class="primary" :disabled="Boolean(pending)">{{ pending === `save:${target.id}` ? "Saugoma..." : "Išsaugoti" }}</button><button type="button" class="secondary" :disabled="Boolean(pending)" @click="cancelEdit">Atšaukti</button></div>
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
    </template>
  </main>
</template>
