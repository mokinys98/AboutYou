import { describe, expect, it, vi } from "vitest";
import { addCatalogFacetInvalidationListener, catalogFacetInvalidationKey } from "./catalogFacetInvalidation";

function storageEvent(key: string | null, newValue: string | null) {
  return Object.assign(new Event("storage"), { key, newValue });
}

describe("catalog facet invalidation listener", () => {
  it("handles only non-removal events for the invalidation key and detaches cleanly", () => {
    const target = new EventTarget();
    const invalidate = vi.fn();
    const removeListener = addCatalogFacetInvalidationListener(target, invalidate);

    target.dispatchEvent(storageEvent("catalog-facets:v4:root", "{}"));
    target.dispatchEvent(storageEvent(catalogFacetInvalidationKey, null));
    expect(invalidate).not.toHaveBeenCalled();

    target.dispatchEvent(storageEvent(catalogFacetInvalidationKey, "1"));
    expect(invalidate).toHaveBeenCalledTimes(1);

    removeListener();
    target.dispatchEvent(storageEvent(catalogFacetInvalidationKey, "2"));
    expect(invalidate).toHaveBeenCalledTimes(1);
  });
});
