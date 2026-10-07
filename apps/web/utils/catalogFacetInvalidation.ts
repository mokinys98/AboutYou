export const catalogFacetInvalidationKey = "catalog-facets:invalidate";

export function addCatalogFacetInvalidationListener(
  target: Pick<EventTarget, "addEventListener" | "removeEventListener">,
  onInvalidate: () => void,
) {
  const listener = (event: Event) => {
    const storageEvent = event as StorageEvent;
    if (storageEvent.key === catalogFacetInvalidationKey && storageEvent.newValue !== null) onInvalidate();
  };
  target.addEventListener("storage", listener);
  return () => target.removeEventListener("storage", listener);
}
