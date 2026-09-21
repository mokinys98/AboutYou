import { describe, expect, it } from "vitest";
import { retryDelayMinutes } from "./catalog-queue";

describe("catalog queue retry policy", () => {
  it("uses bounded backoff before a task is blocked by the database after attempt five", () => {
    expect([1, 2, 3, 4, 5].map(retryDelayMinutes)).toEqual([5, 15, 60, 60, 60]);
  });
});
