export default defineNuxtRouteMiddleware(async (to) => {
  if (import.meta.server || ["/login", "/auth/callback"].includes(to.path)) return;
  const { $supabase } = useNuxtApp();
  const { data } = await $supabase.auth.getSession();
  if (!data.session) return navigateTo("/login");
});

