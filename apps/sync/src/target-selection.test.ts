import { describe, expect, it } from "vitest";
import { selectSyncTargets } from "./target-selection";

describe("selectSyncTargets", () => {
  const targets = [{ label: "Sportas" }, { label: "Batai" }];

  it("selects only the requested target", () => {
    expect(selectSyncTargets(targets, "Sportas")).toEqual([{ label: "Sportas" }]);
  });

  it("keeps all targets when the label is empty", () => {
    expect(selectSyncTargets(targets, "")).toEqual(targets);
  });
});
