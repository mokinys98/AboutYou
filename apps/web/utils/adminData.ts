import type { BrandTier } from "@catalog/shared";

export type TargetKind = "category" | "brand" | "search";
export type Target = {
  id: string;
  label: string;
  url: string;
  kind: TargetKind;
  enabled: boolean;
  priority: number;
  last_success_at: string | null;
  last_error: string | null;
};
export type Run = {
  id: string;
  status: string;
  started_at: string;
  finished_at?: string | null;
  products_count: number;
  error: string | null;
  sync_targets?: { label: string };
};
export type DashboardCategory = { id: string; parentId: string | null; name: string; level: number; path: string; count: number };
export type DashboardStats = {
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
    exactCategoryProducts: number;
    fallbackCategoryProducts: number;
    uncategorizedProducts: number;
    legacyCategories: number;
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
  latestRuns: Run[];
};
export type TeamUser = {
  email: string;
  role: "admin" | "viewer";
  status: "active" | "pending" | "disabled";
  invitedAt: string | null;
  acceptedAt: string | null;
};
export type BrandTierRow = {
  brandKey: string;
  displayName: string;
  activeProducts: number;
  tier: BrandTier | null;
  updatedAt: string | null;
};

export type AdminResourceMap = {
  dashboard: DashboardStats;
  syncTargets: Target[];
  syncRuns: Run[];
  users: TeamUser[];
  brandTiers: BrandTierRow[];
};
export type AdminResourceKey = keyof AdminResourceMap;
export type AdminLoadResult = {
  data: Partial<AdminResourceMap>;
  errors: Partial<Record<AdminResourceKey, string>>;
};

type AdminApi = <T>(path: string) => Promise<T>;

export async function loadAdminResources(api: AdminApi): Promise<AdminLoadResult> {
  const results = await Promise.allSettled([
    Promise.resolve().then(() => api<DashboardStats>("/v1/admin/dashboard")),
    Promise.resolve().then(() => api<Target[]>("/v1/sync-targets")),
    Promise.resolve().then(() => api<Run[]>("/v1/sync-runs")),
    Promise.resolve().then(() => api<TeamUser[]>("/v1/admin/users")),
    Promise.resolve().then(() => api<BrandTierRow[]>("/v1/admin/brand-tiers"))
  ] as const);

  const data: Partial<AdminResourceMap> = {};
  const errors: Partial<Record<AdminResourceKey, string>> = {};
  captureResult(data, errors, "dashboard", results[0], "Dashboard duomenų užkrauti nepavyko");
  captureResult(data, errors, "syncTargets", results[1], "Sinchronizavimo grupių užkrauti nepavyko");
  captureResult(data, errors, "syncRuns", results[2], "Sinchronizavimo darbų užkrauti nepavyko");
  captureResult(data, errors, "users", results[3], "Vartotojų užkrauti nepavyko");
  captureResult(data, errors, "brandTiers", results[4], "Brandų tier'ų užkrauti nepavyko");
  return { data, errors };
}

function captureResult<K extends AdminResourceKey>(
  data: Partial<AdminResourceMap>,
  errors: Partial<Record<AdminResourceKey, string>>,
  key: K,
  result: PromiseSettledResult<AdminResourceMap[K]>,
  fallbackMessage: string
) {
  if (result.status === "fulfilled") {
    data[key] = result.value;
    return;
  }
  errors[key] = result.reason instanceof Error ? result.reason.message : fallbackMessage;
}
