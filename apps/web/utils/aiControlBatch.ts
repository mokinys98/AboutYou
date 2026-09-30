export type AiControlBatchProgress = {
  completed: number;
  analyzed: number;
  skipped: number;
  total: number;
};

export type AiControlBatchResult = AiControlBatchProgress & {
  stopped: boolean;
  error?: unknown;
};

export async function analyzeControlSetSequentially(
  productIds: string[],
  analyze: (productId: string) => Promise<{ skipped: boolean }>,
  onProgress: (progress: AiControlBatchProgress) => void,
  shouldStop: () => boolean
): Promise<AiControlBatchResult> {
  const progress: AiControlBatchProgress = {
    completed: 0, analyzed: 0, skipped: 0, total: productIds.length
  };
  for (const productId of productIds) {
    if (shouldStop()) return { ...progress, stopped: true };
    let result: { skipped: boolean };
    try { result = await analyze(productId); }
    catch (error) { return { ...progress, stopped: false, error }; }
    progress.completed += 1;
    if (result.skipped) progress.skipped += 1;
    else progress.analyzed += 1;
    onProgress({ ...progress });
  }
  return { ...progress, stopped: false };
}
