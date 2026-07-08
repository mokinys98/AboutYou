import { describe, expect, it } from "vitest";
import { sanitizeDiagnosticHtml, summarizeBlockedSchema } from "./metadata-diagnostics";

describe("metadata diagnostic HTML sanitization", () => {
  it("redacts sensitive JSON, form and query-string values", () => {
    const html = `<script>{"accessToken":"abc","email":"a@example.com","safe":"kept"}</script>
      <input name="password" value="guess"><a href="/?token=xyz&item=1">link</a>`;
    const sanitized = sanitizeDiagnosticHtml(html);
    expect(sanitized).not.toContain("abc");
    expect(sanitized).not.toContain("a@example.com");
    expect(sanitized).not.toContain("guess");
    expect(sanitized).not.toContain("xyz");
    expect(sanitized).toContain('"safe":"kept"');
  });
});

describe("blocked schema diagnostics", () => {
  it("groups failures and retains bounded product examples", () => {
    const rows = [
      { last_error_code: "unknown_size_type:future", products: { external_id: "1", name: "A", product_url: "/p/a-1" } },
      { last_error_code: "unknown_size_type:future", products: { external_id: "2", name: "B", product_url: "/p/b-2" } },
      { last_error_code: "unknown_detail_lane:new", products: { external_id: "3", name: "C", product_url: "/p/c-3" } }
    ];
    expect(summarizeBlockedSchema(rows, 1)).toEqual([
      { error_code: "unknown_size_type:future", count: 2, products: [rows[0]?.products] },
      { error_code: "unknown_detail_lane:new", count: 1, products: [rows[2]?.products] }
    ]);
  });
});
