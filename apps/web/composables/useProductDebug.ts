type Member = { userId: string; role: "admin" | "viewer"; email: string };

const member = ref<Member | null>(null);
const memberLoaded = ref(false);
let memberRequest: Promise<void> | null = null;

export function useProductDebug() {
  const api = useApi();
  const cookie = useCookie<"1" | null>("product_debug", {
    default: () => null,
    maxAge: 60 * 60 * 24 * 30,
    path: "/",
    sameSite: "lax",
    secure: typeof window !== "undefined" && window.location.protocol === "https:"
  });

  async function loadMember(force = false) {
    if (force) memberLoaded.value = false;
    if (memberLoaded.value && !force) return;
    if (!memberRequest) {
      memberRequest = api<Member>("/v1/me")
        .then((value) => { member.value = value; })
        .catch(() => { member.value = null; })
        .finally(() => { memberLoaded.value = true; memberRequest = null; });
    }
    await memberRequest;
  }

  function setEnabled(value: boolean) {
    cookie.value = value && member.value?.role === "admin" ? "1" : null;
    if (!value && typeof document !== "undefined") {
      document.cookie = `product_debug=; Max-Age=0; Path=/; SameSite=Lax${window.location.protocol === "https:" ? "; Secure" : ""}`;
    }
  }

  const isAdmin = computed(() => member.value?.role === "admin");
  const enabled = computed(() => isAdmin.value && cookie.value === "1");
  if (import.meta.client) void loadMember();
  return { member: readonly(member), memberLoaded: readonly(memberLoaded), isAdmin, enabled, loadMember, setEnabled };
}
