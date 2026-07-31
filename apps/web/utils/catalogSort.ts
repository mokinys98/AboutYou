export const catalogSortOptions = [
  { value: "newest", label: "Naujausi" },
  { value: "price_asc", label: "Kaina: nuo mažiausios" },
  { value: "price_desc", label: "Kaina: nuo didžiausios" },
  { value: "source_lpl_asc", label: "Paskutinė mažiausia kaina: nuo mažiausios" },
  { value: "source_lpl_desc", label: "Paskutinė mažiausia kaina: nuo didžiausios" },
  { value: "discount_desc", label: "Didžiausia nuolaida" }
] as const;
