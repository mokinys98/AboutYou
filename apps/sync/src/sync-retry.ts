import { classifySyncError, normalizeSyncError, type NormalizedSyncError } from "./sync-errors";

export type RetryEvent = {
  operationName: string;
  attempt: number;
  delayMs: number;
  error: NormalizedSyncError;
};

export type RetryOptions = {
  maxAttempts?: number;
  baseDelayMs?: number;
  jitterRatio?: number;
  sleep?: (milliseconds: number) => Promise<void>;
  random?: () => number;
  onRetry?: (event: RetryEvent) => void;
};

const defaultSleep = (milliseconds: number) => new Promise<void>((resolve) => setTimeout(resolve, milliseconds));

export async function withRetry<T>(
  operationName: string,
  operation: () => Promise<T>,
  options: RetryOptions = {}
): Promise<T> {
  const maxAttempts = options.maxAttempts ?? 3;
  const baseDelayMs = options.baseDelayMs ?? 1_000;
  const jitterRatio = options.jitterRatio ?? 0.2;
  const sleep = options.sleep ?? defaultSleep;
  const random = options.random ?? Math.random;
  let lastError: unknown;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      if (attempt >= maxAttempts || classifySyncError(error) !== "retryable") throw error;

      const baseDelay = baseDelayMs * (2 ** attempt - 1);
      const jitter = 1 + (random() * 2 - 1) * jitterRatio;
      const delayMs = Math.max(0, Math.round(baseDelay * jitter));
      options.onRetry?.({ operationName, attempt, delayMs, error: normalizeSyncError(error) });
      await sleep(delayMs);
    }
  }

  throw lastError;
}
