<script setup lang="ts">
const { member, memberLoaded, isAdmin, enabled, loadMember, setEnabled } = useProductDebug();
onMounted(() => loadMember(true));
</script>

<template>
  <main class="profile-page">
    <header class="page-title"><p class="eyebrow">PASKYRA</p><h1>Profilis</h1></header>
    <p v-if="!memberLoaded">Kraunama…</p>
    <p v-else-if="!member" class="error-state">Profilio informacijos gauti nepavyko.</p>
    <template v-else>
      <dl class="profile-details">
        <div><dt>El. paštas</dt><dd>{{ member.email }}</dd></div>
        <div><dt>Rolė</dt><dd>{{ member.role }}</dd></div>
      </dl>
      <section v-if="isAdmin" class="profile-setting">
        <div><h2>Produkto debug režimas</h2><p>Produkto kortelėse parodo nuorodą į normalizuotus ir pilnus sanitizuotus API duomenis.</p></div>
        <label class="debug-toggle"><input type="checkbox" :checked="enabled" @change="setEnabled(($event.target as HTMLInputElement).checked)"><span>{{ enabled ? "Įjungtas" : "Išjungtas" }}</span></label>
      </section>
    </template>
  </main>
</template>
