import { chromium } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import {
  PRODUCT_DETAIL_ENDPOINT,
  PRODUCT_DETAIL_PARSER_VERSION,
  extractProductDetailFromHtml
} from "@catalog/aboutyou-provider";
import { normalizeCategoryPath, normalizeColor, normalizeColorShade } from "@catalog/shared";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  METADATA_SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(50_000).default(10_000),
  METADATA_SYNC_CLAIM_SIZE: z.coerce.number().int().min(1).max(100).default(25),
  METADATA_SYNC_CONCURRENCY: z.coerce.number().int().min(1).max(12).default(3),
  METADATA_SYNC_DELAY_MS: z.coerce.number().int().min(250).max(60_000).default(400),
  METADATA_SYNC_MAX_RUNTIME_MINUTES: z.coerce.number().int().min(1).max(70).default(60),
  SYNC_HEADLESS: z.string().default("true").transform((value) => value !== "false")
});

type Claim = {
  id: string;
  source_id: string;
  external_id: string;
  name: string;
  brand: string;
  product_url: string;
  lease_token: string;
};

type Counters = {
  claimed: number;
  payload_ok: number;
  complete: number;
  source_absent: number;
  retryable: number;
  blocked_schema: number;
  source_unavailable: number;
};

const env = EnvSchema.parse(process.env);
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});
const counters: Counters = {
  claimed: 0, payload_ok: 0, complete: 0, source_absent: 0,
  retryable: 0, blocked_schema: 0, source_unavailable: 0
};
const startedAt = Date.now();
const deadline = startedAt + env.METADATA_SYNC_MAX_RUNTIME_MINUTES * 60_000;
let rateLimited = false;
let nextRequestAt = Date.now();

log("metadata_sync_started", {
  parser_version: PRODUCT_DETAIL_PARSER_VERSION,
  max_products: env.METADATA_SYNC_MAX_PRODUCTS,
  max_runtime_minutes: env.METADATA_SYNC_MAX_RUNTIME_MINUTES
});

const browser = await chromium.launch({ headless: env.SYNC_HEADLESS });
try {
  const context = await browser.newContext({ locale: "lt-LT", timezoneId: "Europe/Vilnius" });
  while (!rateLimited && counters.claimed < env.METADATA_SYNC_MAX_PRODUCTS && Date.now() < deadline) {
    const remaining = env.METADATA_SYNC_MAX_PRODUCTS - counters.claimed;
    const { data, error } = await db.rpc("claim_product_detail_batch", {
      p_parser_version: PRODUCT_DETAIL_PARSER_VERSION,
      p_limit: Math.min(env.METADATA_SYNC_CLAIM_SIZE, remaining),
      p_lease_minutes: 20
    });
    if (error) throw error;
    const claims = (data ?? []) as Claim[];
    if (!claims.length) break;
    counters.claimed += claims.length;

    await runPool(claims, env.METADATA_SYNC_CONCURRENCY, async (claim) => {
      if (rateLimited) return;
      await waitForRequestSlot();
      try {
        const response = await context.request.get(claim.product_url, {
          failOnStatusCode: false,
          headers: { accept: "text/html,application/xhtml+xml" },
          timeout: 20_000
        });
        const status = response.status();
        if (status === 403 || status === 429) {
          rateLimited = true;
          await fail(claim, "rate_limited", `http_${status}`, status);
          return;
        }
        if (status === 404 || status === 410) {
          counters.source_unavailable += 1;
          await fail(claim, "source_unavailable", `http_${status}`, status);
          return;
        }
        if (!response.ok()) {
          counters.retryable += 1;
          await fail(claim, "retryable", `http_${status}`, status);
          return;
        }

        const finalUrl = new URL(response.url());
        const finalProductId = finalUrl.pathname.match(/-(\d+)\/?$/)?.[1] ?? null;
        if (!finalUrl.pathname.startsWith("/p/") || finalProductId !== claim.external_id) {
          counters.source_unavailable += 1;
          await fail(claim, "source_unavailable", "product_detail_redirected", status);
          return;
        }

        const extraction = extractProductDetailFromHtml(await response.text());
        if (!extraction.rawPayload || !extraction.payloadHash) {
          counters.blocked_schema += 1;
          await fail(claim, "blocked_schema", "product_detail_payload_missing", status);
          return;
        }
        counters.payload_ok += 1;
        if (extraction.sourceProductId !== claim.external_id) {
          counters.blocked_schema += 1;
          await fail(claim, "blocked_schema", "product_detail_id_mismatch", status);
          return;
        }
        if (extraction.schemaError) {
          counters.blocked_schema += 1;
          await fail(claim, "blocked_schema", extraction.schemaError, status);
          return;
        }

        const metadata = extraction.metadata;
        const sourceIsExact = metadata.categories[0]?.toLocaleLowerCase("lt") === "vyrams" && metadata.categories.length >= 2;
        const categoryPath = sourceIsExact ? normalizeCategoryPath(metadata.categories) : [];
        const result = {
          imageUrls: metadata.imageUrls,
          colorOriginal: metadata.colorOriginal,
          colorFamily: normalizeColor(metadata.colorOriginal),
          colorShade: normalizeColorShade(metadata.colorOriginal),
          sizes: metadata.sizeOptions.filter((option) => option.selectable).map((option) => option.label),
          otherSizes: unique(metadata.sizeOptions.flatMap((option) => option.group ? [option.group] : [])),
          materials: metadata.materials,
          patterns: metadata.patterns,
          features: metadata.features,
          styles: metadata.styles,
          productTypes: metadata.productTypes,
          categoryPath,
          categoriesExact: sourceIsExact,
          sections: metadata.sections,
          colorOptions: metadata.colorOptions.map((option, position) => ({ ...option, position })),
          sizeOptions: metadata.sizeOptions.map((option, position) => ({ ...option, position }))
        };
        const { error: completeError } = await db.rpc("complete_product_detail", {
          p_product_id: claim.id,
          p_lease_token: claim.lease_token,
          p_parser_version: PRODUCT_DETAIL_PARSER_VERSION,
          p_payload: extraction.rawPayload,
          p_payload_hash: extraction.payloadHash,
          p_source_endpoint: PRODUCT_DETAIL_ENDPOINT,
          p_result: result
        });
        if (completeError) throw completeError;
        counters.complete += 1;
        counters.source_absent += metadata.sections.filter((section) => section.status === "source_absent").length;
      } catch (error) {
        counters.retryable += 1;
        await fail(claim, "retryable", safeErrorCode(error), null);
      }
    });

    if (rateLimited) {
      const leaseToken = claims[0]?.lease_token;
      if (leaseToken) await db.rpc("release_product_detail_claim", { p_lease_token: leaseToken });
    }
    log("metadata_sync_checkpoint", counters);
  }
} finally {
  await browser.close();
}

const { data: coverage, error: coverageError } = await db.rpc("product_detail_sync_summary", {
  p_parser_version: PRODUCT_DETAIL_PARSER_VERSION
});
if (coverageError) throw coverageError;
log("metadata_sync_finished", {
  ...counters,
  parser_version: PRODUCT_DETAIL_PARSER_VERSION,
  rate_limited: rateLimited,
  duration_seconds: Math.round((Date.now() - startedAt) / 1_000),
  coverage
});

async function fail(
  claim: Claim,
  kind: "rate_limited" | "retryable" | "blocked_schema" | "source_unavailable",
  code: string,
  httpStatus: number | null
): Promise<void> {
  const { error } = await db.rpc("fail_product_detail", {
    p_product_id: claim.id,
    p_lease_token: claim.lease_token,
    p_error_kind: kind,
    p_error_code: code.slice(0, 200),
    p_http_status: httpStatus
  });
  if (error && !String(error.message).includes("lease is missing")) throw error;
}

async function waitForRequestSlot(): Promise<void> {
  const now = Date.now();
  const scheduledAt = Math.max(now, nextRequestAt);
  nextRequestAt = scheduledAt + env.METADATA_SYNC_DELAY_MS;
  if (scheduledAt > now) await new Promise((resolve) => setTimeout(resolve, scheduledAt - now));
}

async function runPool<T>(items: T[], concurrency: number, task: (item: T) => Promise<void>): Promise<void> {
  let cursor = 0;
  const worker = async () => {
    while (cursor < items.length) {
      const item = items[cursor++];
      if (item === undefined) break;
      await task(item);
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
}

function unique(values: string[]): string[] { return [...new Set(values)]; }
function safeErrorCode(error: unknown): string {
  const value = error instanceof Error ? error.message : String(error);
  return `request_failed:${value}`.replace(/\s+/g, " ").slice(0, 200);
}
function log(event: string, values: Record<string, unknown>): void {
  console.log(JSON.stringify({ event, at: new Date().toISOString(), ...values }));
}
