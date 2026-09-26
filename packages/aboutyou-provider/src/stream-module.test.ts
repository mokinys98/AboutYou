import { describe, expect, it } from "vitest";

const categoryServiceAsset = /^https:\/\/assets\.aboutstatic\.com\/assets\/service\.grpc(?:\.lazy)?-[^/]+\.js(?:\?|$)/;

describe("ABOUT YOU category service asset detection", () => {
  it("accepts both current lazy assets and non-lazy asset names", () => {
    expect(categoryServiceAsset.test("https://assets.aboutstatic.com/assets/service.grpc.lazy-_78VexpA-BECoR09M.js")).toBe(true);
    expect(categoryServiceAsset.test("https://assets.aboutstatic.com/assets/service.grpc-B58LEMMV-DPuoVVVn.js")).toBe(true);
  });

  it("does not mistake unrelated JavaScript assets for a service module", () => {
    expect(categoryServiceAsset.test("https://assets.aboutstatic.com/assets/Category.eager-BenQaKu0.js")).toBe(false);
  });
});
