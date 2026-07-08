import { gzip } from "node:zlib";
import { promisify } from "node:util";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { ProductMetadataAttempt } from "@catalog/aboutyou-provider";

const gzipAsync = promisify(gzip);
export const DEBUG_BUCKET = "sync-debug";

export type BlockedSchemaRow = {
  last_error_code: string | null;
  products: {
    external_id: string;
    name: string;
    product_url: string;
  } | Array<{
    external_id: string;
    name: string;
    product_url: string;
  }>;
};

export function summarizeBlockedSchema(rows: BlockedSchemaRow[], sampleLimit = 5) {
  const groups = new Map<string, {
    error_code: string;
    count: number;
    products: Array<{ external_id: string; name: string; product_url: string }>;
  }>();
  for (const row of rows) {
    const errorCode = row.last_error_code ?? "unknown";
    const group = groups.get(errorCode) ?? { error_code: errorCode, count: 0, products: [] };
    group.count += 1;
    const product = Array.isArray(row.products) ? row.products[0] : row.products;
    if (product && group.products.length < sampleLimit) group.products.push(product);
    groups.set(errorCode, group);
  }
  return [...groups.values()].sort((left, right) => right.count - left.count || left.error_code.localeCompare(right.error_code));
}

export function sanitizeDiagnosticHtml(html: string): string {
  return html
    .replace(/("(?:access_?token|refresh_?token|authorization|cookie|email|password|secret)"\s*:\s*")[^"]*(")/gi, "$1[REDACTED]$2")
    .replace(/(<input\b[^>]*\bname=["'](?:password|email|token|secret)["'][^>]*\bvalue=["'])[^"']*(["'])/gi, "$1[REDACTED]$2")
    .replace(/([?&](?:access_?token|refresh_?token|token|secret)=)[^&#"'\s]*/gi, "$1[REDACTED]");
}

export async function uploadDiagnosticHtml(
  db: SupabaseClient,
  productId: string,
  html: string,
  checkedAt = new Date()
): Promise<string> {
  const date = checkedAt.toISOString().slice(0, 10);
  const path = `product-detail-missing/${date}/${productId}.html.gz`;
  const body = await gzipAsync(Buffer.from(sanitizeDiagnosticHtml(html), "utf8"));
  const { error } = await db.storage.from(DEBUG_BUCKET).upload(path, body, {
    contentType: "application/gzip",
    upsert: true
  });
  if (error) throw error;
  return path;
}

export function diagnosticRow(
  productId: string,
  attempt: ProductMetadataAttempt,
  htmlStoragePath: string | null,
  checkedAt: Date
) {
  return {
    product_id: productId,
    checked_at: checkedAt.toISOString(),
    error_code: attempt.error,
    http_status: attempt.httpStatus,
    content_type: attempt.contentType,
    response_size: attempt.responseSize,
    final_url: attempt.finalUrl,
    html_storage_path: htmlStoragePath,
    parser_version: attempt.parserVersion
  };
}

export async function cleanupOldDiagnostics(db: SupabaseClient, retentionDays: number): Promise<number> {
  const cutoff = new Date(Date.now() - retentionDays * 86_400_000).toISOString();
  const pathSet = new Set<string>();
  const pageSize = 1_000;
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await db.from("product_sync_diagnostics")
      .select("html_storage_path").lt("checked_at", cutoff).not("html_storage_path", "is", null)
      .order("id").range(from, from + pageSize - 1);
    if (error) throw error;
    for (const row of data ?? []) if (row.html_storage_path) pathSet.add(row.html_storage_path as string);
    if ((data?.length ?? 0) < pageSize) break;
  }

  const paths = [...pathSet];
  for (let index = 0; index < paths.length; index += 100) {
    const { error: removeError } = await db.storage.from(DEBUG_BUCKET).remove(paths.slice(index, index + 100));
    if (removeError) throw removeError;
  }

  const { error: deleteError, count } = await db.from("product_sync_diagnostics")
    .delete({ count: "exact" }).lt("checked_at", cutoff);
  if (deleteError) throw deleteError;
  return count ?? 0;
}
