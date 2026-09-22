import { duration, sinceStart } from "./sample";
import type { CaptureAnalysis, Cell, Finding, Journey, MarkerKind, Severity } from "@engine/types";

export const fmtSince = sinceStart;
export const fmtDuration = duration;
export const fmtTime = fmtSince;

// ------------------------------------------------------------------------------------------- number precision
//
// One table decides how precise every displayed number is, so no call site can print "RSRP -120.3125 dBm". The
// modem reports RSRP and RSRQ in 1/16 dB steps, throughput in bits per second and timings in fractions of a
// millisecond; past the precision below the extra digits are an artefact of the unit conversion, not measurement,
// and reading them as accuracy is a mistake. Formatting lives here and nowhere else: a call site passes the raw
// value and its unit and gets the string back (audit E5 — the UI never re-rounds a number twice).
//
//   dBm, dB   RSRP / RSRQ / RSSI / SNR / transmit power / headroom      1 decimal
//   %         BLER and other rates                                      1 decimal
//   ms        durations                                                 1 decimal (fmtDuration owns the scale)
//   MHz       carrier centre frequency and bandwidth                    1 decimal
//   Mbit/s    throughput                                                2 significant figures
//   ratio     code rate                                                 2 decimals
//   otherwise MCS, CQI, RI, PMI, PRB, TBS, layers, Qm, TM, antenna
//             counts, band numbers, timing advance, booleans            integer
//
// "2 significant figures" is what a throughput number is worth: 6.577987 Mbit/s is 6.6, 0.000768 is 0.00077. An
// integer default is deliberate — a metric this table does not know is far more likely to be a count or an index
// than a physical quantity, and a spurious ".0" on MCS would be worse than a lost decimal on a new metric.

type Precision = { fixed: number } | { sig: number };

const PRECISION_BY_UNIT: Record<string, Precision> = {
  dBm: { fixed: 1 },
  dB: { fixed: 1 },
  "%": { fixed: 1 },
  ms: { fixed: 1 },
  MHz: { fixed: 1 },
  "Mbit/s": { sig: 2 },
  "kbit/s": { sig: 2 },
  "bit/s": { sig: 2 },
  ratio: { fixed: 2 },
};

/** The precision a unit deserves. Anything not in the table is an index or a count, so: integer. */
function precisionFor(unit: string | null | undefined): Precision {
  return (unit ? PRECISION_BY_UNIT[unit.trim()] : undefined) ?? { fixed: 0 };
}

/** The number alone, rounded to the precision its unit deserves. No unit suffix, no thousands separator. */
export function fmtValue(value: number | null | undefined, unit?: string | null): string {
  if (value == null || !Number.isFinite(value)) return "—";
  const p = precisionFor(unit);
  if ("sig" in p) {
    // toPrecision keeps trailing zeros ("6.6" but also "0.0000" for a true zero); Number() drops them, and the
    // exponent form only appears past 1e21, far outside any radio metric.
    return String(Number(value.toPrecision(p.sig)));
  }
  // -0 prints as "-0" without this, which reads as a measured negative.
  const rounded = Number(value.toFixed(p.fixed));
  return (Object.is(rounded, -0) ? 0 : rounded).toFixed(p.fixed);
}

/** The number with its unit, as a readout prints it: "-91.4 dBm", "6.6 Mbit/s", "17" for a unitless index. */
export function fmtMetric(value: number | null | undefined, unit?: string | null): string {
  const text = fmtValue(value, unit);
  if (text === "—") return text;
  const u = unit?.trim();
  // A "unit" like 'index', 'count', 'PRB' or 'CQI' names the quantity rather than scaling it, and repeating it
  // next to the number ("CQI 9 CQI") says nothing. Only real units are printed.
  return u && PRINTED_UNITS.has(u) ? `${text} ${u}` : text;
}

const PRINTED_UNITS = new Set(["dBm", "dB", "%", "ms", "s", "MHz", "Mbit/s", "kbit/s", "bit/s", "bytes", "PRB"]);

export function fmtTick(ms: number, stepMs: number): string {
  const t = Math.round(Math.max(0, ms));
  const m = Math.floor(t / 60000);
  const s = Math.floor(t / 1000) % 60;
  if (stepMs >= 1000) return `${m}:${String(s).padStart(2, "0")}`;
  if (stepMs >= 100) return `${m}:${String(s).padStart(2, "0")}.${Math.floor((t % 1000) / 100)}`;
  return `${m}:${String(s).padStart(2, "0")}.${String(t % 1000).padStart(3, "0")}`;
}

function offsetFromName(fileName: string): number | null {
  const m = fileName.match(/_(\d{4})\.(\d{2})\.(\d{2})_(\d{2})-(\d{2})-(\d{2})([+-])(\d{2})(\d{2})_/);
  if (!m) return null;
  const sign = m[7] === "+" ? 1 : -1;
  return sign * (Number(m[8]) * 60 + Number(m[9]));
}

function offsetLabel(minutes: number): string {
  const sign = minutes >= 0 ? "+" : "−";
  const abs = Math.abs(minutes);
  const h = Math.floor(abs / 60);
  const m = abs % 60;
  return `UTC${sign}${h}${m ? `:${String(m).padStart(2, "0")}` : ""}`;
}

function phoneDate(analysis: CaptureAnalysis, iso?: string, addMs = 0): { date: Date; zone: string; title: string } | null {
  if (!iso) return null;
  const utc = Date.parse(iso) + addMs;
  if (!Number.isFinite(utc)) return null;
  const off = offsetFromName(analysis.fileName);
  if (off != null) return { date: new Date(utc + off * 60000), zone: offsetLabel(off), title: new Date(utc).toISOString() };
  const d = new Date(utc);
  const zone = new Intl.DateTimeFormat(undefined, { timeZoneName: "short" })
    .formatToParts(d)
    .find((p) => p.type === "timeZoneName")?.value ?? "local";
  return { date: d, zone, title: d.toISOString() };
}

const mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const pad = (n: number) => String(n).padStart(2, "0");

export function wallClock(analysis: CaptureAnalysis, tMs: number): { text: string; title: string } {
  const d = phoneDate(analysis, analysis.startUtc, tMs);
  if (!d) return { text: "—", title: "No network time in this trace" };
  return {
    text: `${pad(d.date.getUTCHours())}:${pad(d.date.getUTCMinutes())}:${pad(d.date.getUTCSeconds())}.${String(d.date.getUTCMilliseconds()).padStart(3, "0")} ${d.zone}`,
    title: d.title,
  };
}

export function recordedAt(analysis: CaptureAnalysis): string {
  const d = phoneDate(analysis, analysis.triggerTime);
  if (!d) return "Recorded time unknown";
  return `${mon[d.date.getUTCMonth()]} ${d.date.getUTCDate()}, ${pad(d.date.getUTCHours())}:${pad(d.date.getUTCMinutes())}:${pad(d.date.getUTCSeconds())} ${d.zone}`;
}

function shortDate(analysis: CaptureAnalysis, iso?: string): string {
  const d = phoneDate(analysis, iso);
  if (!d) return "unknown";
  return `${mon[d.date.getUTCMonth()]} ${d.date.getUTCDate()}`;
}

function rel(ms: number): string {
  const abs = Math.abs(ms);
  if (abs < 90_000) return `${Math.max(1, Math.round(abs / 60_000))} min`;
  if (abs < 36 * 3_600_000) return `${Math.round(abs / 3_600_000)} h`;
  return `${Math.round(abs / 86_400_000)} days`;
}

export function profileLine(analysis: CaptureAnalysis): { text: string; severity: Severity } {
  const now = Date.parse(analysis.guide.evaluatedAt);
  const removal = analysis.guide.removalDate ? Date.parse(analysis.guide.removalDate) : NaN;
  if (analysis.guide.status === "off" || analysis.profile.status === "missing") return { text: "Logging was off", severity: "failure" };
  if (analysis.guide.status === "unknown") return { text: "Unknown", severity: "warning" };
  if (analysis.guide.status === "installedNoTrace") return { text: "Profile installed · no trace found", severity: "warning" };
  if (analysis.guide.status === "expired" && Number.isFinite(removal)) {
    const wasActive = analysis.profile.status === "active" || analysis.profile.status === "expiringSoon";
    return {
      text: wasActive
        ? `Was active when recorded · expired ${rel(now - removal)} ago. Reinstall before your next capture`
        : `Expired ${rel(now - removal)} ago. Reinstall before your next capture`,
      severity: "warning",
    };
  }
  if (analysis.guide.status === "expiringSoon") {
    const today = Number.isFinite(removal) && Math.abs(removal - now) < 86_400_000;
    return { text: today ? "Expires today" : `Active · expires soon (${shortDate(analysis, analysis.guide.removalDate)})`, severity: "warning" };
  }
  if (analysis.guide.status === "active") {
    const days = analysis.guide.daysLeft ?? (Number.isFinite(removal) ? Math.max(0, Math.floor((removal - now) / 86_400_000)) : undefined);
    return { text: days == null ? "Active" : `Active · expires in ${days} days (${shortDate(analysis, analysis.guide.removalDate)})`, severity: "info" };
  }
  return { text: "Unknown", severity: "warning" };
}

export const MARKER_LABEL: Record<MarkerKind, string> = {
  handover: "Handover",
  reselection: "Reselection",
  reattach: "Re-attach",
  redirect: "Redirect",
  reestablishment: "Re-establishment",
  cellChange: "Cell change",
  scgAdd: "5G added",
  scgModify: "5G changed",
  scgRelease: "5G released",
  attach: "Attach",
  detachSwitchOff: "Switch off",
  rrcSetup: "Connected",
  rrcRelease: "Released",
  rach: "Random access",
  failure: "Failure",
  warning: "Warning",
};

export function rsrpQuality(rsrp: number | null | undefined): { label: string; token: string } {
  if (rsrp == null) return { label: "missing", token: "var(--text-3)" };
  if (rsrp >= -85) return { label: "excellent", token: "var(--good)" };
  if (rsrp >= -95) return { label: "good", token: "var(--good)" };
  if (rsrp >= -105) return { label: "fair", token: "var(--warning)" };
  return { label: "poor", token: "var(--critical)" };
}

export function bandForCell(cell: Cell, analysis: CaptureAnalysis | Journey): string | undefined {
  const journey = "journey" in analysis ? analysis.journey : analysis;
  const active = journey.cells.find((c) => sameCell(c.cell, cell));
  if (active) return active.band;
  if ("cellDetails" in analysis && !cell.nr) {
    const detail = analysis.cellDetails.find((d) => sameCell(d.cell, cell));
    if (detail) return `B${detail.band}`;
  }
  return undefined;
}

export function bandChip(cell: Cell, analysis: CaptureAnalysis | Journey): string {
  if (cell.nr && cell.pci === 0xffff) return "NR cell pending";
  const band = bandForCell(cell, analysis);
  if (band) return cell.nr ? `${band} · PCI ${cell.pci}` : `${band} · ${cell.earfcn} / PCI ${cell.pci}`;
  return cell.nr ? `NR PCI ${cell.pci}` : `EARFCN ${cell.earfcn}`;
}

export function sameCell(a: Cell | undefined, b: Cell | undefined): boolean {
  return !!a && !!b && a.earfcn === b.earfcn && a.pci === b.pci && a.nr === b.nr;
}

export function displayText<T extends { summary?: string | undefined; summaryMasked?: string | undefined }>(item: T, masked: boolean): string | undefined {
  return masked ? item.summaryMasked ?? item.summary : item.summary;
}

export function displayFieldValue(field: { value: string; masked?: string | undefined }, masked: boolean): string {
  return masked ? field.masked ?? field.value : field.value;
}

/**
 * The trace window as whole seconds around the button press, signed. The press time is only good to about a
 * second, so the start rounds and the end floors: the window it claims is always one the trace really covers,
 * never a rounded-up second it does not. One helper, so the capture header, the facts list and the coverage card
 * can never print three different windows for the same trace.
 */
export function pressWindow(analysis: CaptureAnalysis): { from: number; to: number } | null {
  const t = analysis.traceWindow;
  if (!t || t.afterPressStartS == null || t.afterPressEndS == null) return null;
  return { from: Math.round(t.afterPressStartS), to: Math.floor(t.afterPressEndS) };
}

/**
 * '\u22124 s' / '+18 s', or '\u22124s' / '+18s' when `compact`. A real minus sign, because a hyphen beside a digit
 * reads as a dash.
 */
export function signedSeconds(n: number, compact = false): string {
  const gap = compact ? "" : " ";
  return n < 0 ? `\u2212${Math.abs(n)}${gap}s` : `+${n}${gap}s`;
}

/**
 * The sentence a finding is printed with. Findings are the analysis's own words (audit E5) with exactly one
 * exception, made here rather than at a call site so every view says the same thing:
 *
 * `carrierAggregation` is counted per journey *segment* upstream, and a carrier that leaves and comes back is a
 * second segment — the real capture reads "6 SCells (B29, B30, B66, B2, B14, B66)" for five carriers, with B66
 * named twice because that one cell served on two SCell indices. Counting distinct carriers (EARFCN + PCI) and
 * naming each band once is presentation, not re-derivation: the segments it counts are the engine's own.
 */
export function findingText(finding: Finding, analysis: CaptureAnalysis): string {
  if (finding.kind !== "carrierAggregation") return finding.text;
  const scells = analysis.journey.cells.filter((c) => c.lane === "scell");
  if (!scells.length) return finding.text;
  const carriers = new Set(scells.map((c) => `${c.cell.earfcn}/${c.cell.pci}`));
  const bands = [...new Set(scells.map((c) => c.band))];
  const pcis = new Set(scells.map((c) => c.cell.pci));
  const onPci = pcis.size === 1 ? ` on PCI ${[...pcis][0]}` : "";
  const first = scells.reduce((a, b) => (b.startMs < a.startMs ? b : a));
  const n = carriers.size;
  return `Carrier aggregation: ${n} ${n === 1 ? "SCell" : "SCells"}${onPci} (${bands.join(", ")}), from ${fmtSince(first.startMs)}.`;
}
