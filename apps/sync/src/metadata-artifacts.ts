import { createHash } from "node:crypto";
import { gzip, gunzip } from "node:zlib";
import { promisify } from "node:util";
import type { SupabaseClient } from "@supabase/supabase-js";

const gzipAsync = promisify(gzip);
const gunzipAsync = promisify(gunzip);
export const RAW_BUCKET = "sync-raw";

export type RawArtifactKind = "success_sample" | "blocked_schema";

export function rawArtifactPath(
  kind: RawArtifactKind,
  parserVersion: number,
  productId: string,
  payloadHash: string,
  createdAt = new Date()
): string {
  if (kind === "success_sample") return `samples/v${parserVersion}/${productId}/${payloadHash}.json.gz`;
  const date = createdAt.toISOString().slice(0, 10);
  return `blocked-schema/${date}/v${parserVersion}/${productId}/${payloadHash}.json.gz`;
}

export async function encodeRawPayload(payload: Record<string, unknown>) {
  const serialized = JSON.stringify(payload);
  const bytes = Buffer.from(serialized, "utf8");
  const compressed = await gzipAsync(bytes);
  return {
    compressed,
    contentHash: createHash("sha256").update(bytes).digest("hex"),
    uncompressedSize: bytes.byteLength,
    compressedSize: compressed.byteLength
  };
}

export async function decodeRawPayload(body: Uint8Array): Promise<Record<string, unknown>> {
  const decoded = await gunzipAsync(body);
  return JSON.parse(decoded.toString("utf8")) as Record<string, unknown>;
}

type ArchiveInput = {
  productId: string;
  payload: Record<string, unknown>;
  payloadHash: string;
  parserVersion: number;
  sourceEndpoint: string;
  kind: RawArtifactKind;
  errorCode?: string | null;
  retentionDays?: number | null;
  createdAt?: Date;
};

export async function archiveRawPayload(db: SupabaseClient, input: ArchiveInput): Promise<boolean> {
  const createdAt = input.createdAt ?? new Date();
  const path = rawArtifactPath(input.kind, input.parserVersion, input.productId, input.payloadHash, createdAt);
  let encoded: Awaited<ReturnType<typeof encodeRawPayload>>;
  try {
    encoded = await encodeRawPayload(input.payload);
    const { error: uploadError } = await db.storage.from(RAW_BUCKET).upload(path, encoded.compressed, {
      contentType: "application/gzip",
      upsert: true
    });
    if (uploadError) throw uploadError;
  } catch (error) {
    await db.from("product_sync_artifacts").insert({
      product_id: input.productId,
      artifact_kind: input.kind,
      payload_hash: input.payloadHash,
      parser_version: input.parserVersion,
      source_endpoint: input.sourceEndpoint,
      error_code: input.errorCode ?? null,
      upload_status: "upload_failed",
      upload_error: safeMessage(error),
      created_at: createdAt.toISOString(),
      expires_at: expiry(createdAt, input.retentionDays ?? 30)
    });
    return false;
  }

  const { error: manifestError } = await db.from("product_sync_artifacts").upsert({
    product_id: input.productId,
    artifact_kind: input.kind,
    storage_path: path,
    payload_hash: input.payloadHash,
    content_hash: encoded.contentHash,
    parser_version: input.parserVersion,
    source_endpoint: input.sourceEndpoint,
    error_code: input.errorCode ?? null,
    uncompressed_size: encoded.uncompressedSize,
    compressed_size: encoded.compressedSize,
    upload_status: "ready",
    upload_error: null,
    created_at: createdAt.toISOString(),
    expires_at: expiry(createdAt, input.retentionDays)
  }, { onConflict: "storage_path" });
  if (manifestError) {
    await db.from("product_sync_artifacts").insert({
      product_id: input.productId,
      artifact_kind: input.kind,
      payload_hash: input.payloadHash,
      parser_version: input.parserVersion,
      source_endpoint: input.sourceEndpoint,
      error_code: input.errorCode ?? null,
      upload_status: "upload_failed",
      upload_error: `manifest: ${manifestError.message}`.slice(0, 500),
      created_at: createdAt.toISOString(),
      expires_at: expiry(createdAt, input.retentionDays ?? 30)
    });
    return false;
  }
  if (input.kind === "success_sample") {
    const { data: superseded, error: supersededError } = await db.from("product_sync_artifacts")
      .select("id,storage_path").eq("product_id", input.productId)
      .eq("artifact_kind", "success_sample").eq("upload_status", "ready").neq("storage_path", path);
    if (supersededError) return false;
    const oldPaths = (superseded ?? []).flatMap((row) => row.storage_path ? [row.storage_path as string] : []);
    if (oldPaths.length) {
      const { error: removeError } = await db.storage.from(RAW_BUCKET).remove(oldPaths);
      if (removeError) return false;
      const { error: deleteError } = await db.from("product_sync_artifacts").delete()
        .in("id", (superseded ?? []).map((row) => row.id));
      if (deleteError) return false;
    }
  }
  return true;
}

export async function cleanupRawArtifacts(db: SupabaseClient, retentionDays: number): Promise<number> {
  const cutoff = new Date(Date.now() - retentionDays * 86_400_000).toISOString();
  const { data: members, error: memberError } = await db.from("product_raw_sample_members").select("product_id");
  if (memberError) throw memberError;
  const memberIds = new Set((members ?? []).map((row) => row.product_id as string));

  const expired: Array<{ id: number; storage_path: string | null }> = [];
  const now = Date.now();
  const cutoffTime = Date.parse(cutoff);
  const pageSize = 1_000;
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await db.from("product_sync_artifacts")
      .select("id,product_id,artifact_kind,storage_path,expires_at,created_at")
      .order("id").range(from, from + pageSize - 1);
    if (error) throw error;
    for (const row of data ?? []) {
      const pastRetention = row.expires_at ? Date.parse(row.expires_at) < now : false;
      const failedPastRetention = row.artifact_kind !== "success_sample" && Date.parse(row.created_at) < cutoffTime;
      const staleSample = row.artifact_kind === "success_sample" && !memberIds.has(row.product_id as string);
      if (pastRetention || failedPastRetention || staleSample) expired.push({ id: row.id as number, storage_path: row.storage_path as string | null });
    }
    if ((data?.length ?? 0) < pageSize) break;
  }

  const paths = expired.flatMap((row) => row.storage_path ? [row.storage_path] : []);
  for (let index = 0; index < paths.length; index += 100) {
    const { error } = await db.storage.from(RAW_BUCKET).remove(paths.slice(index, index + 100));
    if (error) throw error;
  }
  for (let index = 0; index < expired.length; index += 500) {
    const { error } = await db.from("product_sync_artifacts").delete().in("id", expired.slice(index, index + 500).map((row) => row.id));
    if (error) throw error;
  }
  return expired.length;
}

function expiry(createdAt: Date, retentionDays: number | null | undefined): string | null {
  return retentionDays ? new Date(createdAt.getTime() + retentionDays * 86_400_000).toISOString() : null;
}

function safeMessage(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).slice(0, 500);
}
