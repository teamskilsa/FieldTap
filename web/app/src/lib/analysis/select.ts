import type { CaptureAnalysis, Journey, PhyMetric, PhySample, PhySeries, SecurityReport } from "@engine/types";
import { analyzeSecurity } from "@engine/security/report";

/**
 * The fake-base-station report. Real captures carry it from the worker (analyze.ts sets `analysis.security`); the
 * synthetic sample and any analysis built without the pipeline do not, so we compute it here from the same pure,
 * no-network engine function. It is memoised on the analysis object so a re-render does not re-run it.
 */
const cache = new WeakMap<CaptureAnalysis, SecurityReport>();
export function securityOf(analysis: CaptureAnalysis): SecurityReport {
  if (analysis.security) return analysis.security;
  const cached = cache.get(analysis);
  if (cached) return cached;
  const report = analyzeSecurity(analysis);
  cache.set(analysis, report);
  return report;
}

export function seriesOf(a: CaptureAnalysis, metric: PhyMetric): PhySeries | undefined {
  return a.phy.find((s) => s.metric === metric);
}

export function sampleAt(
  series: PhySeries | undefined,
  tMs: number,
  toleranceMs = 1500,
  carrier?: number,
): PhySample | undefined {
  if (!series) return undefined;
  let best: PhySample | undefined;
  for (const s of series.samples) {
    if (carrier != null && s.carrier !== carrier) continue;
    if (s.tMs <= tMs) best = s;
    else break;
  }
  if (!best) return undefined;
  return tMs - best.tMs <= toleranceMs ? best : undefined;
}

export function valueAt(series: PhySeries | undefined, tMs: number, carrier?: number): number | null {
  return sampleAt(series, tMs, 1500, carrier)?.value ?? null;
}

export function activeCells(journey: Journey, tMs: number) {
  return journey.cells.filter((c) => tMs >= c.startMs && tMs <= c.endMs);
}

export function pcellAt(journey: Journey, tMs: number) {
  return activeCells(journey, tMs).find((c) => c.lane === "pcell");
}

export function pscellAt(journey: Journey, tMs: number) {
  return activeCells(journey, tMs).find((c) => c.lane === "pscell");
}

export function nearestEvent(a: CaptureAnalysis, tMs: number) {
  let best = a.events[0];
  let d = Infinity;
  for (const e of a.events) {
    const dd = Math.abs(e.sinceStartMs - tMs);
    if (dd < d) {
      d = dd;
      best = e;
    }
  }
  return best;
}

export function stateAt(journey: Journey, tMs: number) {
  return journey.states.find((s) => tMs >= s.startMs && tMs <= s.endMs)?.state ?? "unknown";
}
