export type SyncTargetLike = { label: string };

export function selectSyncTargets<T extends SyncTargetLike>(targets: T[], requestedLabel: string): T[] {
  return requestedLabel ? targets.filter((target) => target.label === requestedLabel) : targets;
}
