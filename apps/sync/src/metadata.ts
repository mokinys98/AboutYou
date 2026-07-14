import { chromium } from "playwright";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import {
  PRODUCT_DETAIL_ENDPOINT,
  PRODUCT_DETAIL_PARSER_VERSION,
  extractProductDetailFromHtml
} from "@catalog/aboutyou-provider";
import { normalizeCategoryPath, normalizeColor, normalizeColorShade } from "@catalog/shared";
import {
  cleanupOldDiagnostics, diagnosticRow, summarizeBlockedSchema, uploadDiagnosticHtml, type BlockedSchemaRow
} from "./metadata-diagnostics";
import { archiveRawPayload, cleanupRawArtifacts } from "./metadata-artifacts";
import { classifyMetadataExtraction } from "./metadata-policy";

const EnvSchema = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  METADATA_SYNC_MAX_PRODUCTS: z.coerce.number().int().min(1).max(50_000).default(10_000),
  METADATA_SYNC_CLAIM_SIZE: z.coerce.number().int().min(1).max(100).default(25),
  METADATA_SYNC_CONCURRENCY: z.coerce.number().int().min(1).max(12).default(3),
  METADATA_SYNC_DELAY_MS: z.coerce.number().int().min(250).max(60_000).default(400),
  METADATA_SYNC_MAX_RUNTIME_MINUTES: z.coerce.number().int().min(1).max(70).default(60),
  METADATA_DEBUG_HTML_LIMIT: z.coerce.number().int().min(0).max(100).default(20),
  METADATA_DEBUG_RETENTION_DAYS: z.coerce.number().int().min(1).max(90).default(14),
  METADATA_RAW_SAMPLE_LIMIT: z.coerce.number().int().min(1).max(1000).default(750),
  METADATA_RAW_RETENTION_DAYS: z.coerce.number().int().min(1).max(90).default(30),
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
  raw_archived: number;
  raw_archive_failed: number;
};

const env = EnvSchema.parse(process.env);
const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});
const counters: Counters = {
  claimed: 0, payload_ok: 0, complete: 0, source_absent: 0,
  retryable: 0, blocked_schema: 0, source_unavailable: 0,
  raw_archived: 0, raw_archive_failed: 0
};
const startedAt = Date.now();
try {
  const deleted = await cleanupOldDiagnostics(db, env.METADATA_DEBUG_RETENTION_DAYS);
  if (deleted) log("metadata_diagnostics_cleaned", { deleted });
} catch (error) {
  log("metadata_diagnostics_cleanup_failed", { error: safeErrorCode(error) });
}
try {
  const { data: sampleCount, error: refreshError } = await db.rpc("refresh_product_raw_sample_members", {
    p_limit: env.METADATA_RAW_SAMPLE_LIMIT
  });
  if (refreshError) throw refreshError;
  const deleted = await cleanupRawArtifacts(db, env.METADATA_RAW_RETENTION_DAYS);
  log("metadata_raw_sample_refreshed", { sample_count: sampleCount, deleted_artifacts: deleted });
} catch (error) {
  log("metadata_raw_sample_refresh_failed", { error: safeErrorCode(error) });
}
const deadline = startedAt + env.METADATA_SYNC_MAX_RUNTIME_MINUTES * 60_000;
let rateLimited = false;
let nextRequestAt = Date.now();

log("metadata_sync_started", {
  parser_version: PRODUCT_DETAIL_PARSER_VERSION,
  max_products: env.METADATA_SYNC_MAX_PRODUCTS,
  max_runtime_minutes: env.METADATA_SYNC_MAX_RUNTIME_MINUTES
});

await logBlockedSchemaSummary("before_sync");

const browser = await chromium.launch({ headless: env.SYNC_HEADLESS });
let debugHtmlSaved = 0;
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
    const { data: sampleRows, error: sampleError } = await db.from("product_raw_sample_members")
      .select("product_id").in("product_id", claims.map((claim) => claim.id));
    if (sampleError) throw sampleError;
    const sampleIds = new Set((sampleRows ?? []).map((row) => row.product_id as string));

    await runPool(claims, env.METADATA_SYNC_CONCURRENCY, async (claim) => {
      if (rateLimited) return;
      await waitForRequestSlot();
      let responseHtml: string | null = null;
      let httpStatus: number | null = null;
      let contentType: string | null = null;
      let finalUrl: string | null = null;
      try {
        const response = await context.request.get(claim.product_url, {
          failOnStatusCode: false,
          headers: { accept: "text/html,application/xhtml+xml" },
          timeout: 20_000
        });
        const status = response.status();
        httpStatus = status;
        contentType = response.headers()["content-type"] ?? null;
        finalUrl = response.url();
        if (status === 403 || status === 429) {
          rateLimited = true;
          await recordDiagnostic(claim, `http_${status}`, { httpStatus, contentType, finalUrl });
          await fail(claim, "rate_limited", `http_${status}`, status);
          return;
        }
        if (status === 404 || status === 410) {
          counters.source_unavailable += 1;
          await recordDiagnostic(claim, `http_${status}`, { httpStatus, contentType, finalUrl });
          await fail(claim, "source_unavailable", `http_${status}`, status);
          return;
        }
        if (!response.ok()) {
          counters.retryable += 1;
          await recordDiagnostic(claim, `http_${status}`, { httpStatus, contentType, finalUrl });
          await fail(claim, "retryable", `http_${status}`, status);
          return;
        }

        const parsedFinalUrl = new URL(response.url());
        const finalProductId = parsedFinalUrl.pathname.match(/-(\d+)\/?$/)?.[1] ?? null;
        if (!parsedFinalUrl.pathname.startsWith("/p/") || finalProductId !== claim.external_id) {
          counters.source_unavailable += 1;
          await recordDiagnostic(claim, "product_detail_redirected", {
            httpStatus, contentType, finalUrl: parsedFinalUrl.toString()
          });
          await fail(claim, "source_unavailable", "product_detail_redirected", status);
          return;
        }

        responseHtml = await response.text();
        const extraction = extractProductDetailFromHtml(responseHtml);
        const extractionFailure = classifyMetadataExtraction(extraction, claim.external_id);
        if (extractionFailure) {
          counters[extractionFailure.kind === "blocked_schema" ? "blocked_schema" : "retryable"] += 1;
          await recordDiagnostic(claim, extractionFailure.code, {
            httpStatus, contentType, finalUrl, responseHtml
          }, extractionFailure.kind === "blocked_schema" ? {
            payload: extraction.rawPayload,
            payloadHash: extraction.payloadHash
          } : undefined);
          await fail(claim, extractionFailure.kind, extractionFailure.code, status);
          return;
        }
        if (!extraction.rawPayload || !extraction.payloadHash) {
          throw new Error("Validated product detail payload is missing");
        }
        counters.payload_ok += 1;

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
          isPremium: metadata.isPremium,
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
          p_payload_hash: extraction.payloadHash,
          p_source_endpoint: PRODUCT_DETAIL_ENDPOINT,
          p_result: result
        });
        if (completeError) throw completeError;
        counters.complete += 1;
        if (sampleIds.has(claim.id)) {
          const archived = await archiveRawPayload(db, {
            productId: claim.id,
            payload: extraction.rawPayload,
            payloadHash: extraction.payloadHash,
            parserVersion: PRODUCT_DETAIL_PARSER_VERSION,
            sourceEndpoint: PRODUCT_DETAIL_ENDPOINT,
            kind: "success_sample"
          });
          counters[archived ? "raw_archived" : "raw_archive_failed"] += 1;
        }
        counters.source_absent += metadata.sections.filter((section) => section.status === "source_absent").length;
      } catch (error) {
        counters.retryable += 1;
        const code = safeErrorCode(error);
        await recordDiagnostic(claim, code, { httpStatus, contentType, finalUrl, responseHtml });
        await fail(claim, "retryable", code, httpStatus);
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

if (counters.complete > 0) {
  const { data: refreshVersion, error: refreshRequestError } = await db.rpc("request_catalog_items_read_refresh");
  if (refreshRequestError) {
    log("catalog_read_model_refresh_request_failed", {
      products_updated: counters.complete,
      error: refreshRequestError.message
    });
  } else {
    log("catalog_read_model_refresh_requested", {
      products_updated: counters.complete,
      requested_version: refreshVersion
    });
  }
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
await logBlockedSchemaSummary("after_sync");

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

type DiagnosticContext = {
  httpStatus: number | null;
  contentType: string | null;
  finalUrl: string | null;
  responseHtml?: string | null;
};

async function recordDiagnostic(
  claim: Claim,
  error: string,
  context: DiagnosticContext,
  raw?: { payload: Record<string, unknown> | null; payloadHash: string | null }
): Promise<void> {
  const checkedAt = new Date();
  if (raw?.payload && raw.payloadHash) {
    const archived = await archiveRawPayload(db, {
      productId: claim.id,
      payload: raw.payload,
      payloadHash: raw.payloadHash,
      parserVersion: PRODUCT_DETAIL_PARSER_VERSION,
      sourceEndpoint: PRODUCT_DETAIL_ENDPOINT,
      kind: "blocked_schema",
      errorCode: error,
      retentionDays: env.METADATA_RAW_RETENTION_DAYS,
      createdAt: checkedAt
    });
    counters[archived ? "raw_archived" : "raw_archive_failed"] += 1;
  }
  let htmlStoragePath: string | null = null;
  if (context.responseHtml && debugHtmlSaved < env.METADATA_DEBUG_HTML_LIMIT) {
    try {
      htmlStoragePath = await uploadDiagnosticHtml(db, claim.id, context.responseHtml, checkedAt);
      debugHtmlSaved += 1;
    } catch (uploadError) {
      log("metadata_diagnostic_html_upload_failed", {
        external_id: claim.external_id,
        error: safeErrorCode(uploadError)
      });
    }
  }

  const attempt = {
    externalId: claim.external_id,
    rawPayload: null,
    payloadHash: null,
    sourceEndpoint: PRODUCT_DETAIL_ENDPOINT,
    parserVersion: PRODUCT_DETAIL_PARSER_VERSION,
    metadataFound: false,
    error,
    httpStatus: context.httpStatus,
    contentType: context.contentType,
    responseSize: context.responseHtml === undefined || context.responseHtml === null
      ? null
      : Buffer.byteLength(context.responseHtml),
    finalUrl: context.finalUrl,
    responseHtml: context.responseHtml ?? null
  };
  const { error: insertError } = await db.from("product_sync_diagnostics")
    .insert(diagnosticRow(claim.id, attempt, htmlStoragePath, checkedAt));
  if (insertError) {
    log("metadata_diagnostic_insert_failed", {
      external_id: claim.external_id,
      error: insertError.message
    });
  }
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

async function logBlockedSchemaSummary(stage: "before_sync" | "after_sync"): Promise<void> {
  const pageSize = 1_000;
  const rows: BlockedSchemaRow[] = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await db.from("product_detail_sync")
      .select("last_error_code,products!inner(external_id,name,product_url,active)")
      .eq("status", "blocked_schema")
      .eq("parser_version", PRODUCT_DETAIL_PARSER_VERSION)
      .eq("products.active", true)
      .order("product_id")
      .range(from, from + pageSize - 1);
    if (error) {
      log("metadata_blocked_schema_summary_failed", { stage, error: error.message });
      return;
    }
    rows.push(...(data as unknown as BlockedSchemaRow[]));
    if ((data?.length ?? 0) < pageSize) break;
  }
  log("metadata_blocked_schema_summary", {
    stage,
    total: rows.length,
    groups: summarizeBlockedSchema(rows)
  });
}
