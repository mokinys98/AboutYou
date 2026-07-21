import { createClient } from "@supabase/supabase-js";
import { z } from "zod";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  SYNC_STARTED_AT: z.string().datetime({ offset: true }),
  SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).default(50),
  VERIFY_REFRESH_TIMEOUT_MINUTES: z.coerce.number().int().min(1).max(60).default(15),
  VERIFY_REFRESH_POLL_SECONDS: z.coerce.number().int().min(2).max(60).default(15)
});

const env = EnvSchema.parse(process.env);
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const { data: targets, error: targetsError } = await db
  .from("sync_targets")
  .select("id,label")
  .eq("enabled", true);
if (targetsError) fail(`Nepavyko perskaityti aktyvių target'ų: ${targetsError.message}`);

const targetIds = new Set((targets ?? []).map((target) => target.id));
const targetLabels = new Map((targets ?? []).map((target) => [target.id, target.label]));
const { data: runs, error: runsError } = await db
  .from("sync_runs")
  .select("id,target_id,status,products_count,pages_count,error,started_at,finished_at")
  .gte("started_at", env.SYNC_STARTED_AT)
  .order("started_at", { ascending: true });
if (runsError) fail(`Nepavyko perskaityti sync_runs: ${runsError.message}`);

const currentRuns = (runs ?? []).filter((run) => targetIds.has(run.target_id));
const missingTargetIds = [...targetIds].filter((targetId) => !currentRuns.some((run) => run.target_id === targetId));
const failedRuns = currentRuns.filter((run) => run.status !== "success");
const emptyRuns = currentRuns.filter((run) => Number(run.products_count ?? 0) < 1);
const totalProducts = currentRuns.reduce((sum, run) => sum + Number(run.products_count ?? 0), 0);

console.log(JSON.stringify({
  event: "catalog_sync_verification_runs",
  active_targets: targetIds.size,
  runs_found: currentRuns.length,
  total_products: totalProducts,
  expected_max_products_per_target: env.SYNC_MAX_PRODUCTS,
  failed_runs: failedRuns.map((run) => ({
    target: targetLabels.get(run.target_id) ?? run.target_id,
    status: run.status,
    products_count: run.products_count,
    error: run.error
  }))
}));

if (missingTargetIds.length || failedRuns.length || emptyRuns.length) {
  fail(JSON.stringify({
    missing_targets: missingTargetIds.map((targetId) => targetLabels.get(targetId) ?? targetId),
    failed_targets: failedRuns.map((run) => targetLabels.get(run.target_id) ?? run.target_id),
    empty_targets: emptyRuns.map((run) => targetLabels.get(run.target_id) ?? run.target_id)
  }));
}

const deadline = Date.now() + env.VERIFY_REFRESH_TIMEOUT_MINUTES * 60_000;
while (Date.now() <= deadline) {
  const { data: refresh, error: refreshError } = await db
    .from("catalog_read_model_refresh_state")
    .select("requested_version,completed_version,requested_at,last_status,last_duration_ms,last_error,refresh_completed_at")
    .eq("singleton", true)
    .maybeSingle();
  if (refreshError) fail(`Nepavyko perskaityti refresh būsenos: ${refreshError.message}`);

  console.log(JSON.stringify({
    event: "catalog_read_model_refresh_check",
    requested_version: refresh?.requested_version,
    completed_version: refresh?.completed_version,
    requested_at: refresh?.requested_at,
    status: refresh?.last_status,
    duration_ms: refresh?.last_duration_ms,
    error: refresh?.last_error
  }));

  if (refresh && refresh.requested_at && Date.parse(refresh.requested_at) >= Date.parse(env.SYNC_STARTED_AT) &&
      refresh.completed_version >= refresh.requested_version &&
      (refresh.last_status === "refreshed" || refresh.last_status === "clean")) {
    console.log(JSON.stringify({
      event: "catalog_sync_verification_passed",
      active_targets: targetIds.size,
      total_products: totalProducts,
      refresh_duration_ms: refresh.last_duration_ms,
      refresh_completed_at: refresh.refresh_completed_at
    }));
    process.exit(0);
  }

  await new Promise((resolve) => setTimeout(resolve, env.VERIFY_REFRESH_POLL_SECONDS * 1_000));
}

fail(`Read-model refresh nebaigtas per ${env.VERIFY_REFRESH_TIMEOUT_MINUTES} min.`);

function fail(message: string): never {
  console.error(JSON.stringify({ event: "catalog_sync_verification_failed", message }));
  process.exit(1);
}
