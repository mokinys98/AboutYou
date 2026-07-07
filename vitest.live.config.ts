import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["packages/aboutyou-provider/src/**/*.live.ts"],
    testTimeout: 30_000,
    hookTimeout: 30_000
  }
});
