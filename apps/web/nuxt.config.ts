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
