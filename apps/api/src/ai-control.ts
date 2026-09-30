import type { SupabaseClient } from "@supabase/supabase-js";
import { AI_VISUAL_SCHEMA_VERSION, AiVisualAttributesSchema, colorFamilies, colorShades } from "@catalog/shared";

export type AiEnvironment = {
  OPENAI_API_KEY?: string;
  AI_ENRICHMENT_ENABLED?: string;
  AI_CRON_ENABLED?: string;
  AI_INCENTIVE_VERIFIED?: string;
  AI_DAILY_TOKEN_CAP?: string;
};

export const AI_MODEL = "gpt-4.1-2025-04-14";
export const AI_REQUEST_RESERVATION = 10000;
const AI_PROMPT_VERSION = 1;

const enumField = (values: readonly string[]) => ({ type: "string", enum: values });
export const aiOutputFormat = {
  type: "json_schema", name: "catalog_visual_attributes_v1", strict: true,
  schema: {
    type: "object", additionalProperties: false,
    properties: {
      dominantColorFamily: enumField([...colorFamilies, "unknown"]),
      dominantColorShade: enumField([...colorShades, "unknown"]),
      secondaryColorFamilies: { type: "array", items: enumField([...colorFamilies, "unknown"]) },
      temperature: enumField(["warm", "cool", "neutral", "unknown"]),
      lightness: enumField(["light", "medium", "dark", "unknown"]),
      saturation: enumField(["muted", "medium", "vivid", "unknown"]),
      contrast: enumField(["low", "medium", "high", "unknown"]),
      visualPattern: enumField(["solid", "striped", "checked", "floral", "graphic", "other", "unknown"]),
      confidence: { type: "number" },
      needsReview: { type: "boolean" }
    },
    required: ["dominantColorFamily", "dominantColorShade", "secondaryColorFamilies", "temperature",
      "lightness", "saturation", "contrast", "visualPattern", "confidence", "needsReview"]
  }
} as const;

export function aiBudget(env: AiEnvironment) {
  if (env.AI_ENRICHMENT_ENABLED !== "true" || env.AI_INCENTIVE_VERIFIED !== "true" || !env.OPENAI_API_KEY) {
    return { enabled: false, cap: 0 };
  }
  const cap = Number(env.AI_DAILY_TOKEN_CAP);
  if (!Number.isSafeInteger(cap) || cap < AI_REQUEST_RESERVATION || cap > 200000) {
    return { enabled: false, cap: 0 };
  }
  return { enabled: true, cap };
}

function publicImageUrl(value: unknown): value is string {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    return url.protocol === "https:" && !url.username && !url.password && value.length <= 2048 &&
      host !== "localhost" && !host.endsWith(".local") && !host.endsWith(".internal") &&
      !/^\d+(?:\.\d+){3}$/.test(host) && !host.includes(":");
  } catch { return false; }
}

async function sha256(value: string) {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function limitedResponseJson(response: Response): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Empty OpenAI response");
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > 65536) { await reader.cancel(); throw new Error("OpenAI response too large"); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(bytes));
}

export async function analyzeControlItem(db: SupabaseClient, env: AiEnvironment, setId: string, productId: string) {
  const budget = aiBudget(env);
  if (!budget.enabled) throw new Error("AI išjungtas: reikia rakto, patvirtinto pasiūlymo ir dienos limito.");
  const { data: item, error: itemError } = await db.from("ai_control_items")
    .select("product_id").eq("set_id", setId).eq("product_id", productId).maybeSingle();
  if (itemError) throw new Error(itemError.message);
  if (!item) throw new Error("Prekės nėra kontroliniame rinkinyje.");
  const { data: product, error: productError } = await db.from("products")
    .select("id,name,brand,color_original,color_family,color_shade,image_urls,active")
    .eq("id", productId).maybeSingle();
  if (productError || !product?.active) throw new Error("Aktyvi prekė nerasta.");
  const imageUrl = Array.isArray(product.image_urls) ? product.image_urls[0] : null;
  if (!publicImageUrl(imageUrl)) throw new Error("Prekė neturi tinkamos HTTPS nuotraukos.");
  const { data: existing } = await db.from("product_ai_attributes")
    .select("source_image_url,schema_version,prompt_version,metadata_fingerprint").eq("product_id", productId).maybeSingle();
  const metadata = JSON.stringify([product.name, product.brand, product.color_original, product.color_family, product.color_shade]);
  const metadataFingerprint = await sha256(metadata);
  if (existing?.source_image_url === imageUrl && existing.schema_version === AI_VISUAL_SCHEMA_VERSION &&
      existing.prompt_version === AI_PROMPT_VERSION && existing.metadata_fingerprint === metadataFingerprint) {
    return { skipped: true, reason: "Ši nuotrauka ir metaduomenys jau išanalizuoti." };
  }
  const { data: requestId, error: reserveError } = await db.rpc("reserve_ai_control_request", {
    p_set_id: setId, p_product_id: productId, p_image_url: imageUrl,
    p_cap: budget.cap, p_reserve: AI_REQUEST_RESERVATION
  });
  if (reserveError || !requestId) throw new Error(reserveError?.message ?? "Tokenų rezervacija nepavyko.");

  try {
    const response = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}`, "Content-Type": "application/json",
        "Idempotency-Key": requestId },
      body: JSON.stringify({
        model: AI_MODEL, store: false, max_output_tokens: 256,
        instructions: "Classify only visible garment colours and pattern. Ignore background, person and lighting where possible. Return at most two secondary colour families. Use unknown and needsReview=true when uncertain. Return JSON only. Do not infer a person's colour season or identity.",
        input: [{ role: "user", content: [
          { type: "input_text", text: `Product: ${String(product.name).slice(0, 120)}. Brand: ${String(product.brand).slice(0, 80)}. Source colour: ${String(product.color_original ?? "").slice(0, 80)}. Source family: ${product.color_family}. Source shade: ${product.color_shade}. Classify the garment in this image.` },
          { type: "input_image", image_url: imageUrl, detail: "low" }
        ] }],
        text: { format: aiOutputFormat }
      }),
      signal: AbortSignal.timeout(20000)
    });
    const payload = await limitedResponseJson(response) as Record<string, any>;
    if (!response.ok) {
      const errorCode = payload.error?.code;
      const safeCode = typeof errorCode === "string" && /^[a-z0-9_]{1,48}$/.test(errorCode) ? ` ${errorCode}` : "";
      throw new Error(`OpenAI HTTP ${response.status}${safeCode}`);
    }
    if (payload.status !== "completed") throw new Error("OpenAI response incomplete");
    const content = payload.output?.flatMap((part: any) => part.content ?? [])
      .find((part: any) => part.type === "output_text")?.text;
    const parsed = AiVisualAttributesSchema.safeParse(JSON.parse(content ?? "null"));
    const inputTokens = payload.usage?.input_tokens;
    const outputTokens = payload.usage?.output_tokens;
    if (!parsed.success || !Number.isSafeInteger(inputTokens) || !Number.isSafeInteger(outputTokens) ||
        inputTokens < 0 || outputTokens < 0) throw new Error("AI atsakymas arba tokenų apskaita negalioja.");
    const attributes = {
      ...parsed.data,
      needsReview: parsed.data.needsReview || parsed.data.dominantColorFamily === "unknown" ||
        parsed.data.confidence < 0.6 ||
        (product.color_family !== "other" && product.color_family !== parsed.data.dominantColorFamily)
    };
    const { data: currentImage, error: finishError } = await db.rpc("finish_ai_control_request", {
      p_request_id: requestId, p_attributes: attributes, p_input_tokens: inputTokens,
      p_output_tokens: outputTokens, p_image_fingerprint: await sha256(imageUrl),
      p_metadata_fingerprint: metadataFingerprint, p_model: AI_MODEL
    });
    if (finishError) throw new Error(finishError.message);
    return { skipped: false, stored: currentImage, attributes, totalTokens: inputTokens + outputTokens };
  } catch (cause) {
    // After reservation we cannot prove a failed HTTP exchange consumed zero tokens.
    // Keep its full reservation and block the next call until Usage is reconciled.
    const code = cause instanceof Error ? cause.message.slice(0, 80) : "unknown";
    const { error: markError } = await db.from("ai_control_requests")
      .update({ status: "uncertain", error_code: code, finished_at: new Date().toISOString() })
      .eq("id", requestId).eq("status", "reserved");
    if (markError) console.error(JSON.stringify({ event: "ai_uncertain_mark_failed", requestId, code: markError.code }));
    throw new Error("AI kvietimo apskaita neaiški. Nauji kvietimai sustabdyti iki suderinimo.");
  }
}
