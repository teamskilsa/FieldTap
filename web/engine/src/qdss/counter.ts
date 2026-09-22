// Python's collections.Counter as qdss_deframe.py uses it. Keys keep the order of their first increment, as a
// dict does, so the stats serialise with the reference's keys in the reference's order.

export class Counter<K> {
  private readonly counts = new Map<K, number>();

  add(key: K, n = 1): void {
    this.counts.set(key, (this.counts.get(key) ?? 0) + n);
  }

  /** `stats['phase'] = phase`: a plain assignment, kept even when it is 0. */
  set(key: K, n: number): void {
    this.counts.set(key, n);
  }

  get(key: K): number {
    return this.counts.get(key) ?? 0;
  }

  get size(): number {
    return this.counts.size;
  }

  entries(): IterableIterator<[K, number]> {
    return this.counts.entries();
  }

  /** most_common(n): by count, ties in first-seen order (heapq.nlargest is sorted(reverse=True), which is stable). */
  mostCommon(n: number): [K, number][] {
    return [...this.counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, n);
  }

  toObject(name: (key: K) => string = String): Record<string, number> {
    const out: Record<string, number> = {};
    for (const [k, v] of this.counts) out[name(k)] = v;
    return out;
  }
}
