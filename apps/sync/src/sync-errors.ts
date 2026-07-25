export type NormalizedSyncError = {
  name: string | null;
  code: string | null;
  message: string;
  details: string | null;
  hint: string | null;
  status: number | null;
  context: unknown;
};

const SECRET_KEY = /(?:bearer|authorization|cookie|token|service[_-]?role|anon[_-]?key)/i;
const RETRYABLE_SQLSTATE = /^(08|40001|40P01|53300|57014|57P0[123])$/;
const DETERMINISTIC_SQLSTATE = /^(22|23)/;
const RETRYABLE_HTTP = new Set([429, 502, 503, 504]);

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function safeJson(value: unknown, seen = new WeakSet<object>()): unknown {
  if (value === null || typeof value !== "object") return value;
  if (seen.has(value)) return "[circular]";
  seen.add(value);
  if (Array.isArray(value)) return value.slice(0, 20).map((item) => safeJson(item, seen));
  const output: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (SECRET_KEY.test(key)) continue;
    output[key] = safeJson(item, seen);
  }
  return output;
}

export function normalizeSyncError(error: unknown): NormalizedSyncError {
  const object = error && typeof error === "object" ? error as Record<string, unknown> : null;
  const message = error instanceof Error
    ? error.message
    : stringValue(object?.message) ?? (typeof error === "string" ? error : JSON.stringify(safeJson(error)) || String(error));
  return {
    name: error instanceof Error ? error.name : stringValue(object?.name),
    code: stringValue(object?.code) ?? stringValue(object?.sqlState) ?? stringValue(object?.sqlstate),
    message: message.slice(0, 1_000),
    details: stringValue(object?.details)?.slice(0, 1_000) ?? null,
    hint: stringValue(object?.hint)?.slice(0, 1_000) ?? null,
    status: typeof object?.status === "number" ? object.status : null,
    context: error instanceof Error ? null : safeJson(error)
  };
}

export function formatSyncError(error: unknown, maxLength = 2_000): string {
  const normalized = normalizeSyncError(error);
  const serialized = JSON.stringify(normalized);
  return serialized.length <= maxLength ? serialized : `${serialized.slice(0, maxLength - 1)}…`;
}

export function classifySyncError(error: unknown): "retryable" | "deterministic" | "unknown" {
  const normalized = normalizeSyncError(error);
  if (normalized.code && RETRYABLE_SQLSTATE.test(normalized.code)) return "retryable";
  if (normalized.code && DETERMINISTIC_SQLSTATE.test(normalized.code)) return "deterministic";
  if (normalized.status !== null && RETRYABLE_HTTP.has(normalized.status)) return "retryable";
  if (/fetch failed|network|temporar|timeout|gateway|connection reset|connection refused/i.test(normalized.message)) return "retryable";
  return "unknown";
}

export function isDeterministicSyncError(error: unknown): boolean {
  return classifySyncError(error) === "deterministic";
}
