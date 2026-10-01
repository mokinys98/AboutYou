export const AI_CONTROL_MAX_CONCURRENCY = 5;

export function allowedAiControlConcurrency(requested: number, remainingTokens: number, reservationTokens: number) {
  if (!Number.isInteger(requested) || !Number.isFinite(remainingTokens) ||
      !Number.isInteger(reservationTokens) || reservationTokens <= 0) return 0;
  return Math.max(0, Math.min(requested, AI_CONTROL_MAX_CONCURRENCY,
    Math.floor(remainingTokens / reservationTokens)));
}

export type AiControlBatchProgress = {
  completed: number;
  analyzed: number;
  skipped: number;
  total: number;
  averageAiMs: number | null;
};

export type AiControlBatchResult = AiControlBatchProgress & {
  stopped: boolean;
  error?: unknown;
};

type AnalyzeResult = { skipped: boolean };

type BatchOptions = {
  concurrency: number;
  onStart: (productId: string) => void;
  onSettled: (productId: string) => void;
  onProgress: (progress: AiControlBatchProgress, productId: string, result: AnalyzeResult) => void | Promise<void>;
  shouldStop: () => boolean;
  now?: () => number;
};

export async function analyzeControlSetConcurrent(
  productIds: string[],
  analyze: (productId: string) => Promise<AnalyzeResult>,
  options: BatchOptions
): Promise<AiControlBatchResult> {
  if (!Number.isInteger(options.concurrency) || options.concurrency < 1 ||
      options.concurrency > AI_CONTROL_MAX_CONCURRENCY) {
    throw new RangeError(`Concurrency must be between 1 and ${AI_CONTROL_MAX_CONCURRENCY}`);
  }
  const now = options.now ?? (() => performance.now());
  const progress: AiControlBatchProgress = {
    completed: 0, analyzed: 0, skipped: 0, total: productIds.length, averageAiMs: null
  };
  let nextIndex = 0;
  let totalAiMs = 0;
  let firstError: unknown;
  let hasError = false;

  async function worker() {
    while (!hasError && !options.shouldStop()) {
      const index = nextIndex++;
      if (index >= productIds.length) return;
      const productId = productIds[index]!;
      const startedAt = now();
      options.onStart(productId);
      let result: AnalyzeResult;
      try { result = await analyze(productId); }
      catch (error) {
        if (!hasError) { hasError = true; firstError = error; }
        options.onSettled(productId);
        return;
      }
      options.onSettled(productId);
      progress.completed += 1;
      if (result.skipped) progress.skipped += 1;
      else {
        progress.analyzed += 1;
        totalAiMs += Math.max(0, now() - startedAt);
        progress.averageAiMs = totalAiMs / progress.analyzed;
      }
      try { await options.onProgress({ ...progress }, productId, result); }
      catch (error) {
        if (!hasError) { hasError = true; firstError = error; }
        return;
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(options.concurrency, productIds.length) }, () => worker()));
  return { ...progress, stopped: options.shouldStop(), ...(hasError ? { error: firstError } : {}) };
}
