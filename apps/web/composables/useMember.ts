type TeamMember = { userId: string; role: "admin" | "viewer"; email: string };

const memberState = ref<TeamMember | null>(null);
const memberLoaded = ref(false);
let memberRequest: Promise<TeamMember | null> | null = null;

export function useMember() {
  const api = useApi();

  async function loadMember(force = false): Promise<TeamMember | null> {
    if (memberLoaded.value && !force) return memberState.value;
    if (memberRequest && !force) return memberRequest;
    memberRequest = api<TeamMember>("/v1/me")
      .then((member) => {
        memberState.value = member;
        memberLoaded.value = true;
        return member;
      })
      .catch(() => {
        memberState.value = null;
        memberLoaded.value = true;
        return null;
      })
      .finally(() => { memberRequest = null; });
    return memberRequest;
  }

  function clearMember() {
    memberState.value = null;
    memberLoaded.value = false;
    memberRequest = null;
  }

  return {
    member: readonly(memberState),
    loaded: readonly(memberLoaded),
    isAdmin: computed(() => memberState.value?.role === "admin"),
    loadMember,
    clearMember
  };
}
