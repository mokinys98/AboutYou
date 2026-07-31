import { describe, expect, it } from "vitest";
import { catalogSortOptions } from "./catalogSort";

describe("catalog sort options", () => {
  it("places ascending LPL sorting before descending sorting", () => {
    const lplOptions = catalogSortOptions.filter(({ value }) => value.startsWith("source_lpl"));

    expect(lplOptions).toEqual([
      { value: "source_lpl_asc", label: "Paskutinė mažiausia kaina: nuo mažiausios" },
      { value: "source_lpl_desc", label: "Paskutinė mažiausia kaina: nuo didžiausios" }
    ]);
  });
});
