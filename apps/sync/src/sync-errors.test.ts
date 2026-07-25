import { describe, expect, it } from "vitest";
import { classifySyncError, formatSyncError, normalizeSyncError } from "./sync-errors";

describe("sync error normalization", () => {
  it("preserves PostgREST fields instead of producing [object Object]", () => {
    const result = normalizeSyncError({ code: "23514", message: "constraint failed", details: "bad row", hint: "check payload", status: 400 });
    expect(result).toMatchObject({ code: "23514", message: "constraint failed", details: "bad row", hint: "check payload", status: 400 });
    expect(formatSyncError(result)).not.toContain("[object Object]");
  });

  it("redacts secrets and handles circular objects", () => {
    const value: Record<string, unknown> = { authorization: "Bearer secret", message: "failed" };
    value.self = value;
    const output = formatSyncError(value);
    expect(output).not.toContain("secret");
    expect(output).toContain("circular");
  });

  it("classifies transient and deterministic errors", () => {
    expect(classifySyncError({ code: "57014", message: "timeout" })).toBe("retryable");
    expect(classifySyncError({ code: "23505", message: "duplicate" })).toBe("deterministic");
    expect(classifySyncError({ status: 503, message: "gateway" })).toBe("retryable");
  });
});
