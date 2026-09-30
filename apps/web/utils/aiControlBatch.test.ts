import { describe, expect, it, vi } from "vitest";
import { analyzeControlSetSequentially } from "./aiControlBatch";

describe("control set bulk analysis", () => {
  it("runs one product at a time and stops after the first error", async () => {
    const calls: string[] = [];
    let active = 0;
    let maxActive = 0;
    const analyze = vi.fn(async (id: string) => {
      calls.push(id);
      active += 1;
      maxActive = Math.max(maxActive, active);
      await Promise.resolve();
      active -= 1;
      if (id === "second") throw new Error("Daily limit reached");
      return { skipped: false };
    });
    const progress = vi.fn();
    const result = await analyzeControlSetSequentially(
      ["first", "second", "third"], analyze, progress, () => false
    );
    expect(calls).toEqual(["first", "second"]);
    expect(maxActive).toBe(1);
    expect(result).toMatchObject({ completed: 1, analyzed: 1, total: 3, error: new Error("Daily limit reached") });
    expect(progress).toHaveBeenCalledTimes(1);
  });

  it("stops before the next product when cancellation is requested", async () => {
    let stopped = false;
    const analyze = vi.fn(async () => { stopped = true; return { skipped: true }; });
    const result = await analyzeControlSetSequentially(
      ["first", "second"], analyze, () => undefined, () => stopped
    );
    expect(analyze).toHaveBeenCalledTimes(1);
    expect(result).toMatchObject({ completed: 1, skipped: 1, stopped: true });
  });
});
