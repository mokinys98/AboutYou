import type { User } from "@supabase/supabase-js";

const userState = ref<User | null>(null);
const authReady = ref(false);
let listening = false;

export function useAuth() {
  const { $supabase } = useNuxtApp();
  if (import.meta.client && !listening) {
    listening = true;
    $supabase.auth.getUser().then(({ data }) => { userState.value = data.user; authReady.value = true; });
    $supabase.auth.onAuthStateChange((_event, session) => { userState.value = session?.user ?? null; authReady.value = true; });
  }
  const signOut = async () => { await $supabase.auth.signOut(); userState.value = null; await navigateTo("/login"); };
  return { user: readonly(userState), ready: readonly(authReady), signOut };
}

