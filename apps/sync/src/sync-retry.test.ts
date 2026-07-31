import { describe, expect, it, vi } from "vitest";
import { withRetry } from "./sync-retry";

describe("withRetry", () => {
  it("returns immediately when the operation succeeds", async () => {
    const operation = vi.fn(async () => "ok");
    await expect(withRetry("test", operation)).resolves.toBe("ok");
    expect(operation).toHaveBeenCalledTimes(1);
  });

  it("retries transient errors with exponential backoff and jitter", async () => {
    const operation = vi.fn()
      .mockRejectedValueOnce(new TypeError("fetch failed"))
      .mockRejectedValueOnce({ code: "57014", message: "timeout" })
      .mockResolvedValue("ok");
    const sleeps: number[] = [];
    const events: unknown[] = [];

    await expect(withRetry("claim", operation, {
      sleep: async (milliseconds) => { sleeps.push(milliseconds); },
      random: () => 0.5,
      onRetry: (event) => events.push(event)
    })).resolves.toBe("ok");

    expect(sleeps).toEqual([1_000, 3_000]);
    expect(events).toHaveLength(2);
    expect(events[0]).toMatchObject({ operationName: "claim", attempt: 1, delayMs: 1_000 });
    expect(operation).toHaveBeenCalledTimes(3);
  });

  it("retries HTTP gateway errors and keeps jitter within the configured bounds", async () => {
    const operation = vi.fn()
      .mockRejectedValueOnce({ status: 503, message: "gateway" })
      .mockResolvedValue("ok");
    const sleeps: number[] = [];

    await expect(withRetry("refresh", operation, {
      sleep: async (milliseconds) => { sleeps.push(milliseconds); },
      random: () => 0
    })).resolves.toBe("ok");

    expect(sleeps[0]).toBe(800);
    expect(operation).toHaveBeenCalledTimes(2);
  });

  it("does not retry deterministic or unknown errors", async () => {
    const deterministic = vi.fn(async () => { throw { code: "23505", message: "duplicate" }; });
    const unknown = vi.fn(async () => { throw new Error("invalid payload"); });

    await expect(withRetry("deterministic", deterministic, { sleep: async () => undefined })).rejects.toMatchObject({ code: "23505" });
    await expect(withRetry("unknown", unknown, { sleep: async () => undefined })).rejects.toThrow("invalid payload");
    expect(deterministic).toHaveBeenCalledTimes(1);
    expect(unknown).toHaveBeenCalledTimes(1);
  });

  it("stops after the configured number of transient attempts", async () => {
    const operation = vi.fn(async () => { throw new TypeError("fetch failed"); });
    await expect(withRetry("summary", operation, { sleep: async () => undefined })).rejects.toThrow("fetch failed");
    expect(operation).toHaveBeenCalledTimes(3);
  });
});
