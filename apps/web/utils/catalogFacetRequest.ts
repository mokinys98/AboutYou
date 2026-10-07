export interface FacetRequestHandle<T> {
  promise: Promise<T>;
  controller: AbortController;
  valid: boolean;
}

/** Short-lived in-memory facet cache plus per-key request coalescing. */
export class CatalogFacetRequestCache<T> {
  private readonly values = new Map<string, { value: T; cachedAt: number }>();
  private readonly pending = new Map<string, FacetRequestHandle<T>>();

  constructor(private readonly ttlMs: number) {}

  get size() {
    return this.values.size;
  }

  get(key: string, now = Date.now()): T | undefined {
    const entry = this.values.get(key);
    if (!entry) return undefined;
    if (now - entry.cachedAt > this.ttlMs) {
      this.values.delete(key);
      return undefined;
    }
    return entry.value;
  }

  set(key: string, value: T, now = Date.now()) {
    for (const [cachedKey, entry] of this.values) {
      if (now - entry.cachedAt > this.ttlMs) this.values.delete(cachedKey);
    }
    this.values.set(key, { value, cachedAt: now });
  }

  getPending(key: string) {
    return this.pending.get(key);
  }

  request(key: string, load: (signal: AbortSignal) => Promise<T>, force = false): FacetRequestHandle<T> {
    const existing = this.pending.get(key);
    if (existing && !force) return existing;
    if (existing) {
      existing.valid = false;
      existing.controller.abort();
      this.pending.delete(key);
    }

    const controller = new AbortController();
    const handle: FacetRequestHandle<T> = {
      controller,
      valid: true,
      promise: Promise.resolve(undefined as T),
    };
    handle.promise = load(controller.signal).then((value) => {
      if (handle.valid && this.pending.get(key) === handle) this.set(key, value);
      return value;
    }).finally(() => {
      if (this.pending.get(key) === handle) this.pending.delete(key);
    });
    this.pending.set(key, handle);
    return handle;
  }

  invalidate() {
    this.values.clear();
    for (const handle of this.pending.values()) {
      handle.valid = false;
      handle.controller.abort();
    }
    this.pending.clear();
  }
}
