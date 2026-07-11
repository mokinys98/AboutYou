export default defineNuxtRouteMiddleware(async () => {
  if (import.meta.server) return;
  const { loadMember } = useMember();
  const member = await loadMember();
  if (member?.role !== "admin") return navigateTo("/");
});
