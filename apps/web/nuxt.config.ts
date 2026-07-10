import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const appDir = dirname(fileURLToPath(import.meta.url));
const rootEnvPath = resolve(appDir, "..", "..", ".env");

if (existsSync(rootEnvPath)) {
  for (const line of readFileSync(rootEnvPath, "utf8").split(/\r?\n/)) {
    const match = line.match(/^\s*([\w.-]+)\s*=\s*(.*)?\s*$/);
    const key = match?.[1];
    if (!key || key in process.env) {
      continue;
    }

    process.env[key] = (match[2] ?? "").replace(/^(['"])(.*)\1$/, "$2");
  }
}

export default defineNuxtConfig({
  compatibilityDate: "2026-07-05",
  ssr: false,
  devtools: { enabled: true },
  nitro: { preset: "cloudflare-pages" },
  css: ["~/assets/main.css"],
  runtimeConfig: {
    public: {
      supabaseUrl: process.env.NUXT_PUBLIC_SUPABASE_URL ?? "",
      supabaseAnonKey: process.env.NUXT_PUBLIC_SUPABASE_ANON_KEY ?? "",
      apiBase: process.env.NUXT_PUBLIC_API_BASE ?? "http://localhost:8787"
    }
  },
  app: {
    head: {
      title: "KAINORAŠTIS",
      meta: [{ name: "viewport", content: "width=device-width, initial-scale=1" }]
    }
  },
  typescript: { strict: true }
});
