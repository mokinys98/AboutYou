import { classifySyncError, formatSyncError, normalizeSyncError } from "./sync-errors";

export type CatalogBatchItem = { externalId?: string };
export type CatalogBatchFailureEvent = {
  batchSize: number;
  payloadBytes: number;
  attempt: number;
  durationMs: number;
  firstExternalId: string | null;
  lastExternalId: string | null;
  error: ReturnType<typeof normalizeSyncError>;
};

export type CatalogBatchRejected = {
  externalId: string | null;
  error: ReturnType<typeof normalizeSyncError>;
};

type Options<T extends CatalogBatchItem> = {
  items: T[];
  save: (items: T[]) => Promise<number>;
  onFailure?: (event: CatalogBatchFailureEvent) => void;
  maxRetryAttempts?: number;
  sleep?: (ms: number) => Promise<void>;
};

export type CatalogBatchResult = {
  saved: number;
  rejected: CatalogBatchRejected[];
};

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function payloadBytes(items: unknown[]): number {
  return new TextEncoder().encode(JSON.stringify(items)).byteLength;
}

export async function saveCatalogBatchResilient<T extends CatalogBatchItem>(options: Options<T>): Promise<CatalogBatchResult> {
  const maxRetryAttempts = options.maxRetryAttempts ?? 3;
  const sleep = options.sleep ?? defaultSleep;

  async function save(items: T[]): Promise<CatalogBatchResult> {
    let attempt = 0;
    while (true) {
      attempt += 1;
      const startedAt = Date.now();
      try {
        return { saved: await options.save(items), rejected: [] };
      } catch (error) {
        options.onFailure?.({
          batchSize: items.length,
          payloadBytes: payloadBytes(items),
          attempt,
          durationMs: Date.now() - startedAt,
          firstExternalId: items[0]?.externalId ?? null,
          lastExternalId: items.at(-1)?.externalId ?? null,
          error: normalizeSyncError(error)
        });
        const category = classifySyncError(error);
        if (category === "deterministic" && items.length > 1) {
          const midpoint = Math.ceil(items.length / 2);
          const left = await save(items.slice(0, midpoint));
          const right = await save(items.slice(midpoint));
          return { saved: left.saved + right.saved, rejected: [...left.rejected, ...right.rejected] };
        }
        const allowedAttempts = category === "retryable" ? maxRetryAttempts : category === "unknown" ? 2 : 1;
        if (attempt < allowedAttempts) {
          await sleep(attempt === 1 ? 1_000 : 3_000);
          continue;
        }
        if (category === "deterministic" && items.length === 1) {
          return {
            saved: 0,
            rejected: [{ externalId: items[0]?.externalId ?? null, error: normalizeSyncError(error) }]
          };
        }
        throw new Error(formatSyncError(error));
      }
    }
  }

  return save(options.items);
}
