<script setup lang="ts">
import { colorFamilies, colorShades } from "@catalog/shared";

type ControlSet = { id: string; name: string; catalog_url: string; created_at: string };
type Product = { id: string; name: string; brand: string; product_url: string; image_urls: string[];
  color_original: string | null; color_family: string; color_shade: string; active: boolean };
type Ai = { dominant_color_family: string; dominant_color_shade: string; secondary_color_families: string[];
  temperature: string; lightness: string; saturation: string; contrast: string; visual_pattern: string;
  confidence: number; needs_review: boolean; source_image_url: string; analyzed_at: string; model: string };
type ControlItem = { set_id: string; product_id: string; products: Product; ai: Ai | null;
  human_color_family: string | null; human_color_shade: string | null; human_temperature: string | null;
  human_lightness: string | null; human_saturation: string | null; human_contrast: string | null;
  human_visual_pattern: string | null; review_note: string | null; reviewed_at: string | null };
type CatalogItem = { id: string; name: string; brand: string; imageUrls: string[]; colorFamily: string;
  currentPrice: number; currency: string };
type CatalogPage = { items: CatalogItem[]; nextCursor: string | null; total: number };
type Request = { id: string; status: string; product_id: string; reserved_tokens: number;
  actual_tokens: number | null; error_code: string | null; created_at: string };
type Usage = { budget: { enabled: boolean; cap: number }; usage: { reserved_total: number; actual_total: number } | null;
  requests: Request[] };

const api = useApi();
const sets = ref<ControlSet[]>([]);
const selectedSet = ref<string>("");
const items = ref<ControlItem[]>([]);
const usage = ref<Usage | null>(null);
const name = ref("");
const catalogUrl = ref("https://rinkissaupigiausia.online/?category=vyrams%3Edrabu%C5%BEiai%3Emar%C5%A1kin%C4%97liai&price_min=20&price_max=40");
const preview = ref<CatalogItem[]>([]);
const nextCursor = ref<string | null>(null);
const selectedIds = ref<string[]>([]);
const busy = ref("");
const message = ref("");
const error = ref("");
const editingId = ref("");
const reconciliationTokens = ref("");
const reconciliationError = ref("");
const review = reactive({ colorFamily: "", colorShade: "", temperature: "", lightness: "", saturation: "",
  contrast: "", visualPattern: "", note: "" });
const activeSet = computed(() => sets.value.find((set) => set.id === selectedSet.value));
const uncertain = computed(() => usage.value?.requests.find((request) =>
  request.status === "uncertain" || request.status === "reserved"));
const analyzedCount = computed(() => items.value.filter((item) => item.ai?.source_image_url === item.products?.image_urls?.[0]).length);
const reviewedCount = computed(() => items.value.filter((item) => item.reviewed_at).length);
const familyOptions = ["", ...colorFamilies, "unknown"];
const shadeOptions = ["", ...colorShades, "unknown"];
const temperatureOptions = ["", "warm", "cool", "neutral", "unknown"];
const lightnessOptions = ["", "light", "medium", "dark", "unknown"];
const saturationOptions = ["", "muted", "medium", "vivid", "unknown"];
const contrastOptions = ["", "low", "medium", "high", "unknown"];
const patternOptions = ["", "solid", "striped", "checked", "floral", "graphic", "other", "unknown"];

function errorMessage(cause: unknown) {
  const detail = cause && typeof cause === "object" && "data" in cause
    ? (cause as { data?: { error?: unknown } }).data?.error : null;
  return typeof detail === "string" ? detail : cause instanceof Error ? cause.message : "Veiksmas nepavyko.";
}
function report(cause: unknown) { error.value = errorMessage(cause); }
async function refresh() {
  const [setRows, budget] = await Promise.all([
    api<ControlSet[]>("/v1/admin/ai-control/sets"),
    api<Usage>("/v1/admin/ai-control/usage")
  ]);
  sets.value = setRows;
  usage.value = budget;
  if (!selectedSet.value && setRows.length) selectedSet.value = setRows[0]!.id;
  if (selectedSet.value) await loadItems();
}
async function loadItems() {
  if (!selectedSet.value) { items.value = []; return; }
  items.value = await api<ControlItem[]>(`/v1/admin/ai-control/sets/${selectedSet.value}/items`);
}
function catalogQuery(cursor?: string) {
  const source = new URL(activeSet.value?.catalog_url ?? catalogUrl.value);
  const query = new URLSearchParams(source.search);
  if (query.has("price_min")) query.set("price_min", String(Math.round(Number(query.get("price_min")) * 100)));
  if (query.has("price_max")) query.set("price_max", String(Math.round(Number(query.get("price_max")) * 100)));
  query.set("limit", "100");
  if (cursor) query.set("cursor", cursor); else query.delete("cursor");
  return query;
}
async function loadPreview(more = false) {
  error.value = "";
  busy.value = "preview";
  try {
    const page = await api<CatalogPage>(`/v1/catalog?${catalogQuery(more ? nextCursor.value ?? undefined : undefined)}`);
    preview.value = more ? [...preview.value, ...page.items] : page.items;
    nextCursor.value = page.nextCursor;
    if (!more) selectedIds.value = [];
  } catch (cause) { report(cause); }
  finally { busy.value = ""; }
}
async function createSet() {
  error.value = ""; message.value = ""; busy.value = "create";
  try {
    const created = await api<ControlSet>("/v1/admin/ai-control/sets", {
      method: "POST", body: { name: name.value, catalogUrl: catalogUrl.value }
    });
    sets.value.unshift(created);
    selectedSet.value = created.id;
    items.value = []; preview.value = []; selectedIds.value = [];
    message.value = "Rinkinys sukurtas. Peržiūrėkite filtrą ir pasirinkite prekes.";
  } catch (cause) { report(cause); }
  finally { busy.value = ""; }
}
async function addSelected() {
  if (!selectedSet.value || !selectedIds.value.length) return;
  error.value = ""; busy.value = "add";
  try {
    await api(`/v1/admin/ai-control/sets/${selectedSet.value}/items`, {
      method: "POST", body: { productIds: selectedIds.value }
    });
    message.value = `Pridėta ${selectedIds.value.length} prekių.`;
    selectedIds.value = [];
    await loadItems();
  } catch (cause) { report(cause); }
  finally { busy.value = ""; }
}
async function analyze(item: ControlItem) {
  error.value = ""; message.value = ""; busy.value = item.product_id;
  try {
    const result = await api<{ skipped: boolean; totalTokens?: number }>(
      `/v1/admin/ai-control/sets/${selectedSet.value}/items/${item.product_id}/analyze`, { method: "POST" });
    message.value = result.skipped ? "Ši prekė jau išanalizuota." : `AI išvada gauta. Panaudota ${result.totalTokens} tokenų.`;
    await Promise.all([loadItems(), api<Usage>("/v1/admin/ai-control/usage").then((value) => { usage.value = value; })]);
  } catch (cause) { report(cause); await refresh().catch(() => undefined); }
  finally { busy.value = ""; }
}
function editReview(item: ControlItem) {
  editingId.value = item.product_id;
  Object.assign(review, { colorFamily: item.human_color_family ?? "", colorShade: item.human_color_shade ?? "",
    temperature: item.human_temperature ?? "", lightness: item.human_lightness ?? "",
    saturation: item.human_saturation ?? "", contrast: item.human_contrast ?? "",
    visualPattern: item.human_visual_pattern ?? "", note: item.review_note ?? "" });
}
async function saveReview(item: ControlItem) {
  error.value = ""; busy.value = `review:${item.product_id}`;
  try {
    const emptyToNull = (value: string) => value || null;
    await api(`/v1/admin/ai-control/sets/${selectedSet.value}/items/${item.product_id}/review`, {
      method: "PUT", body: {
        colorFamily: emptyToNull(review.colorFamily), colorShade: emptyToNull(review.colorShade),
        temperature: emptyToNull(review.temperature), lightness: emptyToNull(review.lightness),
        saturation: emptyToNull(review.saturation), contrast: emptyToNull(review.contrast),
        visualPattern: emptyToNull(review.visualPattern), note: review.note
      }
    });
    editingId.value = ""; message.value = "Žmogaus žyma išsaugota."; await loadItems();
  } catch (cause) { report(cause); }
  finally { busy.value = ""; }
}
async function removeItem(item: ControlItem) {
  error.value = ""; busy.value = `remove:${item.product_id}`;
  try {
    await api(`/v1/admin/ai-control/sets/${selectedSet.value}/items/${item.product_id}`, { method: "DELETE" });
    await loadItems();
  } catch (cause) { report(cause); }
  finally { busy.value = ""; }
}
async function reconcile() {
  const request = uncertain.value;
  const input = reconciliationTokens.value.trim();
  if (!request) { reconciliationError.value = "Nėra nesuderintos užklausos. Atnaujinkite puslapį."; return; }
  if (!/^(0|[1-9]\d*)$/.test(input) || Number(input) > 20000) {
    reconciliationError.value = "Įrašykite sveiką tokenų skaičių nuo 0 iki 20000.";
    return;
  }
  error.value = ""; message.value = ""; reconciliationError.value = ""; busy.value = "reconcile";
  try {
    await api(`/v1/admin/ai-control/requests/${request.id}/reconcile`, {
      method: "POST", body: { actualTokens: Number(input) }
    });
    reconciliationTokens.value = "";
    message.value = "Užklausa suderinta.";
    try { usage.value = await api<Usage>("/v1/admin/ai-control/usage"); }
    catch { reconciliationError.value = "Suderinta, bet būsenos atnaujinti nepavyko. Perkraukite puslapį."; }
  } catch (cause) { reconciliationError.value = errorMessage(cause); }
  finally { busy.value = ""; }
}
function optionLabel(value: string) { return value ? value.replaceAll("_", " ") : "— nepažymėta —"; }
function mismatch(human: string | null, ai: string | undefined) { return human && ai && human !== ai; }
onMounted(() => { refresh().catch(report); });
watch(selectedSet, () => { preview.value = []; selectedIds.value = []; nextCursor.value = null; loadItems().catch(report); });
</script>

<template>
  <div class="ai-control">
    <div class="ai-heading">
      <div><p class="eyebrow">KONTROLINIS RINKINYS</p><h2>AI spalvų analizė</h2>
        <p>Pasirinkite katalogo filtrą, iš jo sudarykite 50–100 prekių imtį ir lyginkite AI išvadą su žmogaus žyma.</p></div>
      <div class="ai-budget" :class="{ ready: usage?.budget.enabled }">
        <strong>{{ usage?.budget.enabled ? "AI įjungtas" : "AI išjungtas" }}</strong>
        <span>Šiandien: {{ usage?.usage?.actual_total ?? 0 }} / {{ usage?.budget.cap ?? 0 }} tokenų</span>
        <small>Rezervuota: {{ usage?.usage?.reserved_total ?? 0 }}</small>
      </div>
    </div>
    <p v-if="error" class="error-state" role="alert">{{ error }}</p>
    <p v-if="message" class="success-state" role="status">{{ message }}</p>
    <div v-if="uncertain" class="ai-alert">
      <strong>AI apskaita neaiški · {{ uncertain.id }}</strong>
      <p>Patikrinkite šią užklausą OpenAI Usage. Įrašykite faktinį bendrą tokenų skaičių; jei Usage patvirtina, kad užklausa nebuvo įvykdyta, įrašykite 0. Dar vykdomą užklausą galima suderinti tik po 2 minučių. Iki suderinimo nauji kvietimai blokuojami.</p>
      <p class="ai-request-detail">Būsena: {{ uncertain.status }} · Sukurta: {{ new Date(uncertain.created_at).toLocaleString("lt-LT") }}<template v-if="uncertain.error_code"> · Priežastis: {{ uncertain.error_code }}</template></p>
      <form novalidate @submit.prevent="reconcile"><label>Faktiniai tokenai<input v-model="reconciliationTokens" type="text" inputmode="numeric" maxlength="5" autocomplete="off"></label><button type="submit" class="secondary" :disabled="Boolean(busy)">{{ busy === "reconcile" ? "Derinama…" : "Suderinti" }}</button></form>
      <p v-if="reconciliationError" class="ai-reconciliation-error" role="alert">{{ reconciliationError }}</p>
    </div>

    <section class="admin-panel ai-setup">
      <h3>Naujas rinkinys</h3>
      <form @submit.prevent="createSet">
        <label>Pavadinimas<input v-model="name" required maxlength="120" placeholder="Marškinėliai 20–40 €"></label>
        <label>Katalogo filtro nuoroda<input v-model="catalogUrl" required type="url" placeholder="https://rinkissaupigiausia.online/?category=..."></label>
        <button class="primary" :disabled="Boolean(busy)">Sukurti rinkinį</button>
      </form>
    </section>

    <section class="admin-panel">
      <div class="ai-section-heading"><h3>Rinkinys</h3>
        <select v-model="selectedSet" aria-label="Pasirinkite rinkinį"><option value="">Pasirinkite</option><option v-for="set in sets" :key="set.id" :value="set.id">{{ set.name }}</option></select>
      </div>
      <template v-if="activeSet">
        <a :href="activeSet.catalog_url" target="_blank" rel="noopener noreferrer">Atidaryti katalogo filtrą ↗</a>
        <p class="panel-note">{{ items.length }} prekių · {{ analyzedCount }} AI išvadų · {{ reviewedCount }} žmogaus žymų</p>
        <div class="ai-actions"><button class="secondary" :disabled="Boolean(busy)" @click="loadPreview(false)">Peržiūrėti filtro prekes</button>
          <button class="primary" :disabled="!selectedIds.length || Boolean(busy)" @click="addSelected">Pridėti pasirinktas ({{ selectedIds.length }})</button></div>
        <div v-if="preview.length" class="ai-preview-grid">
          <label v-for="product in preview" :key="product.id" class="ai-preview-card">
            <input v-model="selectedIds" type="checkbox" :value="product.id" :disabled="items.some((item) => item.product_id === product.id)">
            <img v-if="product.imageUrls?.[0]" :src="product.imageUrls[0]" alt="" loading="lazy">
            <span><strong>{{ product.brand }}</strong><small>{{ product.name }}</small><small>{{ (product.currentPrice / 100).toFixed(2) }} {{ product.currency }}</small></span>
          </label>
        </div>
        <button v-if="nextCursor" class="secondary ai-more" :disabled="Boolean(busy)" @click="loadPreview(true)">Rodyti daugiau</button>
      </template>
    </section>

    <section v-if="activeSet" class="ai-results">
      <h3>Kontrolinės prekės</h3>
      <p v-if="!items.length" class="panel-note">Pirmiausia pasirinkite prekes iš filtro.</p>
      <div class="ai-result-grid">
        <article v-for="item in items" :key="item.product_id" class="ai-result-card">
          <img v-if="item.products?.image_urls?.[0]" :src="item.products.image_urls[0]" :alt="item.products.name" loading="lazy">
          <div class="ai-card-body">
            <div class="ai-card-title"><div><small>{{ item.products?.brand }}</small><h4><NuxtLink :to="`/products/${item.product_id}`" target="_blank" rel="noopener noreferrer" class="ai-product-link" title="Atidaryti prekės puslapį naujame skirtuke">{{ item.products?.name || item.product_id }} ↗</NuxtLink></h4></div>
              <button class="ai-text-button" :disabled="Boolean(busy)" @click="removeItem(item)">Pašalinti</button></div>
            <p class="ai-source">Katalogas: {{ item.products?.color_family }} / {{ item.products?.color_shade }}</p>
            <div v-if="item.ai && item.ai.source_image_url === item.products?.image_urls?.[0]" class="ai-output">
              <div class="ai-output-heading"><strong>AI išvada</strong><small>{{ Math.round(item.ai.confidence * 100) }} % tikrumas</small></div>
              <div class="ai-attribute-list">
                <span><b>Spalva</b>{{ item.ai.dominant_color_family }} / {{ item.ai.dominant_color_shade }}</span>
                <span><b>Antros spalvos</b>{{ item.ai.secondary_color_families?.join(", ") || "—" }}</span>
                <span><b>Temperatūra</b>{{ item.ai.temperature }}</span>
                <span><b>Šviesumas</b>{{ item.ai.lightness }}</span>
                <span><b>Sodrumas</b>{{ item.ai.saturation }}</span>
                <span><b>Kontrastas</b>{{ item.ai.contrast }}</span>
                <span><b>Raštas</b>{{ item.ai.visual_pattern }}</span>
              </div>
              <p v-if="item.ai.needs_review" class="ai-review-flag">AI prašo peržiūros</p>
              <small>{{ item.ai.model }} · {{ new Date(item.ai.analyzed_at).toLocaleString("lt-LT") }}</small>
            </div>
            <p v-else class="ai-empty">AI išvados nėra arba nuotrauka pasikeitė.</p>
            <button class="secondary" :disabled="Boolean(busy) || !usage?.budget.enabled" @click="analyze(item)">{{ busy === item.product_id ? "Analizuojama…" : "Analizuoti su AI" }}</button>
            <div class="ai-human">
              <div class="ai-output-heading"><strong>Žmogaus žyma</strong><button class="ai-text-button" @click="editReview(item)">{{ item.reviewed_at ? "Keisti" : "Žymėti" }}</button></div>
              <div v-if="item.reviewed_at" class="ai-attribute-list">
                <span :class="{ 'ai-mismatch': mismatch(item.human_color_family, item.ai?.dominant_color_family) }"><b>Spalva</b>{{ item.human_color_family || "?" }}</span>
                <span :class="{ 'ai-mismatch': mismatch(item.human_color_shade, item.ai?.dominant_color_shade) }"><b>Atspalvis</b>{{ item.human_color_shade || "?" }}</span>
                <span :class="{ 'ai-mismatch': mismatch(item.human_temperature, item.ai?.temperature) }"><b>Temperatūra</b>{{ item.human_temperature || "?" }}</span>
                <span :class="{ 'ai-mismatch': mismatch(item.human_lightness, item.ai?.lightness) }"><b>Šviesumas</b>{{ item.human_lightness || "?" }}</span>
                <span :class="{ 'ai-mismatch': mismatch(item.human_saturation, item.ai?.saturation) }"><b>Sodrumas</b>{{ item.human_saturation || "?" }}</span>
                <span :class="{ 'ai-mismatch': mismatch(item.human_contrast, item.ai?.contrast) }"><b>Kontrastas</b>{{ item.human_contrast || "?" }}</span>
                <span :class="{ 'ai-mismatch': mismatch(item.human_visual_pattern, item.ai?.visual_pattern) }"><b>Raštas</b>{{ item.human_visual_pattern || "?" }}</span>
              </div><p v-else class="panel-note">Dar nepažymėta</p>
              <p v-if="item.review_note">{{ item.review_note }}</p>
            </div>
            <form v-if="editingId === item.product_id" class="ai-review-form" @submit.prevent="saveReview(item)">
              <label>Spalvų šeima<select v-model="review.colorFamily"><option v-for="value in familyOptions" :key="value" :value="value">{{ optionLabel(value) }}</option></select></label>
              <label>Atspalvis<select v-model="review.colorShade"><option v-for="value in shadeOptions" :key="value" :value="value">{{ optionLabel(value) }}</option></select></label>
              <label>Temperatūra<select v-model="review.temperature"><option v-for="value in temperatureOptions" :key="value" :value="value">{{ optionLabel(value) }}</option></select></label>
              <label>Šviesumas<select v-model="review.lightness"><option v-for="value in lightnessOptions" :key="value" :value="value">{{ optionLabel(value) }}</option></select></label>
              <label>Sodrumas<select v-model="review.saturation"><option v-for="value in saturationOptions" :key="value" :value="value">{{ optionLabel(value) }}</option></select></label>
              <label>Kontrastas<select v-model="review.contrast"><option v-for="value in contrastOptions" :key="value" :value="value">{{ optionLabel(value) }}</option></select></label>
              <label>Raštas<select v-model="review.visualPattern"><option v-for="value in patternOptions" :key="value" :value="value">{{ optionLabel(value) }}</option></select></label>
              <label class="ai-note">Pastaba<textarea v-model="review.note" maxlength="500" rows="2" placeholder="Kodėl išvada teisinga arba ne?" /></label>
              <div class="ai-actions"><button class="primary" :disabled="Boolean(busy)">Išsaugoti</button><button type="button" class="secondary" @click="editingId = ''">Atšaukti</button></div>
            </form>
          </div>
        </article>
      </div>
    </section>
  </div>
</template>

<style scoped>
.ai-control{display:grid;gap:24px}.ai-heading,.ai-section-heading,.ai-output-heading,.ai-card-title{display:flex;align-items:start;justify-content:space-between;gap:16px}.ai-heading h2{margin:5px 0}.ai-heading p{max-width:730px}.ai-budget{display:grid;gap:4px;min-width:190px;padding:15px;border:1px solid #ddd;background:#fafafa}.ai-budget.ready{border-color:#168347;background:#f2fbf5}.ai-budget small,.ai-budget span,.ai-source,.ai-output small{color:#666}.ai-alert{padding:18px;border:1px solid #d19131;background:#fff8e8}.ai-alert form,.ai-actions{display:flex;flex-wrap:wrap;gap:10px;align-items:center}.ai-alert input{width:130px;padding:9px}.ai-setup form{display:grid;grid-template-columns:minmax(180px,1fr) minmax(320px,2fr) auto;gap:12px;align-items:end}.ai-setup label,.ai-review-form label{display:grid;gap:6px;font-size:12px;font-weight:700}.ai-setup input,.ai-section-heading select,.ai-review-form select,.ai-review-form textarea{width:100%;padding:10px;border:1px solid #bbb;background:#fff}.ai-preview-grid,.ai-result-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(235px,1fr));gap:14px;margin-top:18px}.ai-preview-card{display:grid;grid-template-columns:18px 64px 1fr;gap:9px;align-items:start;padding:9px;border:1px solid #ddd;cursor:pointer}.ai-preview-card img{width:64px;height:88px;object-fit:contain}.ai-preview-card span{display:grid;gap:5px}.ai-preview-card small{font-size:11px}.ai-preview-card:has(input:checked){border-color:#111;background:#f6f6f6}.ai-more{margin-top:14px}.ai-results h3{margin:0}.ai-result-card{border:1px solid #ddd;background:#fff;overflow:hidden}.ai-result-card>img{width:100%;height:250px;object-fit:contain;background:#f8f8f8}.ai-card-body{padding:15px;display:grid;gap:12px}.ai-card-title h4{margin:4px 0;font-size:14px}.ai-product-link{color:inherit;text-decoration:underline;text-underline-offset:2px}.ai-product-link:hover{color:#126b45}.ai-product-link:focus-visible{outline:2px solid #126b45;outline-offset:3px}.ai-card-title small{text-transform:uppercase;letter-spacing:.06em}.ai-text-button{border:0;background:none;text-decoration:underline;cursor:pointer;font-size:12px}.ai-output,.ai-human{padding:12px;border:1px solid #e1e1e1;background:#fafafa}.ai-human{background:#fff}.ai-attribute-list{display:grid;grid-template-columns:1fr 1fr;gap:9px;margin:12px 0}.ai-attribute-list span{display:grid;gap:3px;font-size:12px}.ai-attribute-list b{font-size:10px;color:#666;text-transform:uppercase}.ai-review-flag,.ai-mismatch{color:#9b4818}.ai-mismatch{background:#fff0e6;padding:3px}.ai-empty{color:#666;font-size:12px}.ai-review-form{display:grid;grid-template-columns:1fr 1fr;gap:10px;padding-top:8px}.ai-review-form .ai-note,.ai-review-form .ai-actions{grid-column:1/-1}@media(max-width:850px){.ai-setup form{grid-template-columns:1fr}.ai-heading{display:block}.ai-budget{max-width:300px}}
.ai-alert label{display:grid;gap:6px;font-size:12px;font-weight:700}
.ai-alert label input{font-size:14px;font-weight:400}
.ai-request-detail{font-size:13px;color:#67501d}
.ai-reconciliation-error{margin:10px 0 0;color:#b42318;font-size:13px}
</style>
