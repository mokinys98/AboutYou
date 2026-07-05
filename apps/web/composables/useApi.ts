export function useApi() {
  const config = useRuntimeConfig();
  const { $supabase } = useNuxtApp();
  return async function api<T>(path: string, options: Parameters<typeof $fetch<T>>[1] = {}): Promise<T> {
    const { data } = await $supabase.auth.getSession();
    if (!data.session) { await navigateTo("/login"); throw new Error("Sesija negalioja"); }
    return $fetch<T>(`${config.public.apiBase}${path}`, {
      ...options,
      headers: { ...options.headers, Authorization: `Bearer ${data.session.access_token}` }
    });
  };
}

