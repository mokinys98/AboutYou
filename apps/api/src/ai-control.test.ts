import { afterEach, describe, expect, it, vi } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import { aiBudget, aiOutputFormat, analyzeControlItem } from "./ai-control";

const env = { AI_ENRICHMENT_ENABLED: "true", AI_INCENTIVE_VERIFIED: "true",
  AI_DAILY_TOKEN_CAP: "200000", OPENAI_API_KEY: "test-only" };

function fakeDb(response: unknown, status = 200) {
  const rpc = vi.fn(async (name: string) => name === "reserve_ai_control_request"
    ? { data: "request-id", error: null } : { data: true, error: null });
  const updates: unknown[] = [];
  const db = {
    from(table: string) {
      if (table === "ai_control_items") return { select: () => ({ eq: () => ({ eq: () => ({ maybeSingle: async () => ({ data: { product_id: "product-id" }, error: null }) }) }) }) };
      if (table === "products") return { select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: {
        id: "product-id", active: true, name: "Blue shirt", brand: "Brand", color_original: "blue",
        color_family: "blue", color_shade: "navy", image_urls: ["https://images.example.com/shirt.jpg"]
      }, error: null }) }) }) };
      if (table === "product_ai_attributes") return { select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: null }) }) }) };
      if (table === "ai_control_requests") return { update: (value: unknown) => {
        updates.push(value);
        return { eq: () => ({ eq: async () => ({ error: null }) }) };
      } };
      throw new Error(`Unexpected table ${table}`);
    },
    rpc
  } as unknown as SupabaseClient;
  const fetchMock = vi.fn(async () => Response.json(response, { status }));
  vi.stubGlobal("fetch", fetchMock);
  return { db, rpc, updates, fetchMock };
}

afterEach(() => vi.unstubAllGlobals());

describe("AI control cost gate", () => {
  it("rejects missing proof, key and oversized caps before any DB or network call", async () => {
    expect(aiBudget({ ...env, AI_INCENTIVE_VERIFIED: "false" }).enabled).toBe(false);
    expect(aiBudget({ ...env, OPENAI_API_KEY: undefined }).enabled).toBe(false);
    expect(aiBudget({ ...env, AI_DAILY_TOKEN_CAP: "800000" }).enabled).toBe(false);
    const network = vi.fn(); vi.stubGlobal("fetch", network);
    await expect(analyzeControlItem({} as SupabaseClient, { ...env, AI_ENRICHMENT_ENABLED: "false" }, "s", "p"))
      .rejects.toThrow("AI išjungtas");
    expect(network).not.toHaveBeenCalled();
  });

  it("reserves tokens before sending one low detail structured request and records usage", async () => {
    const attributes = { dominantColorFamily: "blue", dominantColorShade: "navy",
      secondaryColorFamilies: [], temperature: "cool", lightness: "dark", saturation: "muted",
      contrast: "medium", visualPattern: "solid", confidence: 0.9, needsReview: false };
    const { db, rpc, fetchMock } = fakeDb({ status: "completed", output: [{ content: [{ type: "output_text", text: JSON.stringify(attributes) }] }],
      usage: { input_tokens: 410, output_tokens: 80 } });
    const result = await analyzeControlItem(db, env, "set-id", "product-id");
    expect(result).toMatchObject({ skipped: false, stored: true, totalTokens: 490 });
    expect(rpc.mock.calls.map((call) => call[0])).toEqual(["reserve_ai_control_request", "finish_ai_control_request"]);
    const request = JSON.parse((fetchMock.mock.calls[0] as unknown as [string, RequestInit])[1].body as string);
    expect(request.input[0].content[1]).toMatchObject({ detail: "low" });
    expect(request.text.format).toEqual(aiOutputFormat);
    expect(request.max_output_tokens).toBe(256);
  });

  it("blocks following calls when a response has no usage", async () => {
    const { db, updates } = fakeDb({ output: [], usage: null });
    await expect(analyzeControlItem(db, env, "set-id", "product-id"))
      .rejects.toThrow("apskaita neaiški");
    expect(updates).toMatchObject([{ status: "uncertain" }]);
  });

  it("records the OpenAI error code for a rejected request without retrying", async () => {
    const { db, updates, fetchMock } = fakeDb({ error: { code: "project_spend_limit_exceeded" } }, 429);
    await expect(analyzeControlItem(db, env, "set-id", "product-id"))
      .rejects.toThrow("apskaita neaiški");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(updates).toMatchObject([{
      status: "uncertain", error_code: "OpenAI HTTP 429 project_spend_limit_exceeded"
    }]);
  });
});
