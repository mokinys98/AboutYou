import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { archiveRawPayload, decodeRawPayload, encodeRawPayload, RAW_BUCKET, rawArtifactPath } from "./metadata-artifacts";

const env = z.object({
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  METADATA_RAW_SAMPLE_LIMIT: z.coerce.number().int().min(1).max(1000).default(750)
}).parse(process.env);

const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const { error: refreshError } = await db.rpc("refresh_product_raw_sample_members", {
  p_limit: env.METADATA_RAW_SAMPLE_LIMIT
});
if (refreshError) throw refreshError;

const { data: memberRows, error: memberError } = await db.from("product_raw_sample_members")
  .select("product_id").order("sample_rank");
if (memberError) throw memberError;
const memberIds = (memberRows ?? []).map((row) => row.product_id as string);
let archived = 0;
let verified = 0;

for (let index = 0; index < memberIds.length; index += 25) {
  const { data: rows, error } = await db.from("product_detail_raw")
    .select("product_id,payload,payload_hash,parser_version,source_endpoint")
    .in("product_id", memberIds.slice(index, index + 25));
  if (error) throw error;
  for (const row of rows ?? []) {
    const input = {
      productId: row.product_id as string,
      payload: row.payload as Record<string, unknown>,
      payloadHash: row.payload_hash as string,
      parserVersion: row.parser_version as number,
      sourceEndpoint: row.source_endpoint as string,
      kind: "success_sample" as const
    };
    if (!await archiveRawPayload(db, input)) throw new Error(`Raw archive upload failed for ${input.productId}`);
    archived += 1;

    const path = rawArtifactPath(input.kind, input.parserVersion, input.productId, input.payloadHash);
    const { data: downloaded, error: downloadError } = await db.storage.from(RAW_BUCKET).download(path);
    if (downloadError) throw downloadError;
    const decoded = await decodeRawPayload(new Uint8Array(await downloaded.arrayBuffer()));
    const encoded = await encodeRawPayload(decoded);
    const { data: manifest, error: manifestError } = await db.from("product_sync_artifacts")
      .select("content_hash").eq("storage_path", path).single();
    if (manifestError) throw manifestError;
    if (manifest.content_hash !== encoded.contentHash) throw new Error(`Raw archive hash mismatch for ${input.productId}`);
    verified += 1;
  }
  console.log(JSON.stringify({ event: "raw_archive_checkpoint", archived, verified, requested: memberIds.length }));
}

if (archived !== verified) throw new Error(`Verified ${verified} of ${archived} archived payloads`);
console.log(JSON.stringify({ event: "raw_archive_finished", selected: memberIds.length, archived, verified }));
