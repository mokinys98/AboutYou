import { describe, expect, it, vi } from "vitest";
import { allowedAiControlConcurrency, analyzeControlSetConcurrent } from "./aiControlBatch";

const callbacks = () => ({
  onStart: vi.fn(),
  onSettled: vi.fn(),
  onProgress: vi.fn(),
  shouldStop: () => false
});

describe("control set concurrent analysis", () => {
  it("reduces concurrency when the daily budget cannot reserve five requests", () => {
    expect(allowedAiControlConcurrency(5, 19000, 10000)).toBe(1);
    expect(allowedAiControlConcurrency(5, 9000, 10000)).toBe(0);
    expect(allowedAiControlConcurrency(5, 90000, 10000)).toBe(5);
  });

  it("never exceeds the selected concurrency", async () => {
    let active = 0;
    let maxActive = 0;
    const result = await analyzeControlSetConcurrent(
      Array.from({ length: 12 }, (_, index) => String(index)),
      async () => {
        active += 1;
        maxActive = Math.max(maxActive, active);
        await new Promise((resolve) => setTimeout(resolve, 1));
        active -= 1;
        return { skipped: false };
      },
      { ...callbacks(), concurrency: 5 }
    );
    expect(maxActive).toBe(5);
    expect(result).toMatchObject({ completed: 12, analyzed: 12, total: 12 });
  });

  it("stops scheduling after the first error and lets started requests finish", async () => {
    let finishFirst: (() => void) | undefined;
    const calls: string[] = [];
    const batch = analyzeControlSetConcurrent(
      ["first", "second", "third"],
      async (id) => {
        calls.push(id);
        if (id === "first") await new Promise<void>((resolve) => { finishFirst = resolve; });
        if (id === "second") throw new Error("Daily limit reached");
        return { skipped: false };
      },
      { ...callbacks(), concurrency: 2 }
    );
    await Promise.resolve();
    finishFirst!();
    const result = await batch;
    expect(calls).toEqual(["first", "second"]);
    expect(result).toMatchObject({ completed: 1, analyzed: 1, error: new Error("Daily limit reached") });
  });

  it("stops before the next product when cancellation is requested", async () => {
    let stopped = false;
    const analyze = vi.fn(async () => { stopped = true; return { skipped: true }; });
    const result = await analyzeControlSetConcurrent(
      ["first", "second"], analyze,
      { ...callbacks(), concurrency: 1, shouldStop: () => stopped }
    );
    expect(analyze).toHaveBeenCalledTimes(1);
    expect(result).toMatchObject({ completed: 1, skipped: 1, stopped: true });
  });

  it("waits for the UI refresh before reusing a slot", async () => {
    const events: string[] = [];
    await analyzeControlSetConcurrent(
      ["first", "second"],
      async (id) => { events.push(`analyze:${id}`); return { skipped: false }; },
      {
        ...callbacks(), concurrency: 1,
        onProgress: async (progress) => {
          await Promise.resolve();
          events.push(`refresh:${progress.completed}`);
        }
      }
    );
    expect(events).toEqual(["analyze:first", "refresh:1", "analyze:second", "refresh:2"]);
  });

  it("stops before spending on another request when updating the UI fails", async () => {
    const analyze = vi.fn(async () => ({ skipped: false }));
    const result = await analyzeControlSetConcurrent(
      ["first", "second"], analyze,
      { ...callbacks(), concurrency: 1, onProgress: async () => { throw new Error("Refresh failed"); } }
    );
    expect(analyze).toHaveBeenCalledTimes(1);
    expect(result).toMatchObject({ completed: 1, analyzed: 1, error: new Error("Refresh failed") });
  });

  it("calculates average AI request duration without cached skips", async () => {
    let clock = 0;
    const result = await analyzeControlSetConcurrent(
      ["first", "cached", "third"],
      async (id) => {
        clock += id === "first" ? 100 : id === "third" ? 300 : 1;
        return { skipped: id === "cached" };
      },
      { ...callbacks(), concurrency: 1, now: () => clock }
    );
    expect(result).toMatchObject({ completed: 3, analyzed: 2, skipped: 1, averageAiMs: 200 });
  });
});
