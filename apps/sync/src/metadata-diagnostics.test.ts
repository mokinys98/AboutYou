import { describe, expect, it } from "vitest";
import { sanitizeDiagnosticHtml } from "./metadata-diagnostics";

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
