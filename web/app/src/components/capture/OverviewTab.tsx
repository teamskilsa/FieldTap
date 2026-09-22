// Overview: what happened, the facts about the recording, and the measurement tiles.
//
// Every sentence and every tile value is the analysis's own string (audit E5) — nothing here re-derives a number,
// so the list and the tiles can never disagree. A finding click only moves the cursor; it never opens a modal
// (audit A26).
import { Link } from "@tanstack/react-router";
import {
  ArrowLeftRight, BadgeCheck, CircleCheck, CirclePlus, Clock, Crosshair, Info, Layers, Lock, OctagonX, PhoneCall,
  Power, RefreshCcw, TriangleAlert, type LucideIcon,
} from "lucide-react";
import { StatusIcon } from "@/components/capture/CaptureHeader";
import type { RadioSection } from "@/components/capture/RadioTab";
import { findingText, fmtDuration, fmtSince, pressWindow, profileLine, recordedAt, signedSeconds } from "@/lib/analysis/format";
import { useBandPalette, type BandPalette } from "@/lib/analysis/palette";
import { pcellAt, seriesOf } from "@/lib/analysis/select";
import type { CaptureAnalysis, Finding, FindingKind, PhySeries, Procedure, Tile } from "@engine/types";
import { cn } from "@/lib/utils";

/** The group subtitles say what the 3GPP word means to someone who is not a telecom engineer (audit A29). */
const GROUPS: { id: Tile["group"]; note: string }[] = [
  { id: "Accessibility", note: "getting connected" },
  { id: "Mobility", note: "moving between cells" },
  { id: "EN-DC", note: "the 5G leg" },
  { id: "Retainability", note: "keeping the connection" },
  { id: "Integrity", note: "how much the radio carried" },
];

const ICONS: Record<FindingKind, LucideIcon> = {
  radioOffOn: Power,
  switchedOffAtEnd: Power,
  reattach: RefreshCcw,
  attach: BadgeCheck,
  imsPdn: PhoneCall,
  endcAdded: CirclePlus,
  scgPhyOutlived: TriangleAlert,
  handover: ArrowLeftRight,
  carrierAggregation: Layers,
  failure: OctagonX,
  failures: OctagonX,
  warning: TriangleAlert,
  noFailures: CircleCheck,
  encryptedRecords: Lock,
  traceWindow: Clock,
  other: Info,
};

export function OverviewTab({
  analysis, masked, onJump, onOpenFlow, onOpenRadio, onShowOnTimeline,
}: {
  analysis: CaptureAnalysis;
  masked: boolean;
  onJump: (tMs: number, event?: number) => void;
  onOpenFlow: (procedure?: string) => void;
  onOpenRadio: (section?: RadioSection) => void;
  /** Glide the timeline cursor there and flash the moment, without leaving this tab. */
  onShowOnTimeline: (tMs: number) => void;
}) {
  const palette = useBandPalette(analysis);
  const timed = analysis.journey.findings.filter((f) => f.tMs != null);
  const tail = analysis.journey.findings.filter((f) => f.tMs == null);
  const failures = analysis.journey.findings.filter((f) => f.severity === "failure").length;

  return (
    <div className="grid min-w-0 grid-cols-1 gap-4 lg:grid-cols-12">
      {/* The story column. The coverage card comes first because a reader who is confused about what they are
          looking at is confused about the window, not about the findings. */}
      <div className="min-w-0 space-y-4 lg:col-span-8">
        <CoverageCard analysis={analysis} />

        <section className="panel min-w-0 overflow-hidden" aria-labelledby="what-happened">
          <div className="flex h-12 items-center border-b border-[var(--line)] px-3">
            <div>
              <h2 id="what-happened" className="text-[13px] font-medium">What happened</h2>
              <p className="text-xs text-[var(--text-3)]">
                {analysis.journey.findings.length} findings · {failures} {failures === 1 ? "failure" : "failures"}
              </p>
            </div>
          </div>
          {timed.map((f) => (
            <FindingRow key={f.id} finding={f} analysis={analysis} palette={palette} onJump={onJump} onOpenFlow={onOpenFlow} onShowOnTimeline={onShowOnTimeline} />
          ))}
          {tail.length > 0 && (
            <>
              <p className="border-y border-[var(--line)] bg-[var(--surface-2)] px-3 py-1 text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">
                Summary
              </p>
              {tail.map((f) => (
                <FindingRow key={f.id} finding={f} analysis={analysis} palette={palette} onJump={onJump} onOpenFlow={onOpenFlow} onShowOnTimeline={onShowOnTimeline} />
              ))}
            </>
          )}
        </section>
      </div>

      <aside className="min-w-0 lg:col-span-4">
        <CaptureFacts analysis={analysis} onOpenRadio={onOpenRadio} />
      </aside>

      <section className="min-w-0 space-y-5 lg:col-span-12" aria-label="Key measurements">
        {GROUPS.map(({ id, note }) => {
          const tiles = analysis.journey.tiles.filter((t) => t.group === id);
          if (!tiles.length) return null;
          return (
            <div key={id} className="min-w-0">
              <h3 className="text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">
                {id} <span className="normal-case text-[var(--text-3)]">· {note}</span>
              </h3>
              <div className="mt-2 grid min-w-0 gap-3 [grid-template-columns:repeat(auto-fill,minmax(220px,1fr))]">
                {tiles.map((tile) => (
                  <KpiTile key={tile.id} tile={tile} analysis={analysis} onJump={onJump} onOpenFlow={onOpenFlow} onOpenRadio={onOpenRadio} />
                ))}
              </div>
            </div>
          );
        })}
      </section>

      <section className="panel min-w-0 p-4 lg:col-span-12">
        <h2 className="text-[13px] font-medium">Cells this capture saw</h2>
        <div className="mt-2 overflow-x-auto">
          <table className="w-full min-w-[560px] text-[13px]">
            <thead>
              <tr className="border-b border-[var(--line)] text-left text-[11px] uppercase tracking-[0.02em] text-[var(--text-3)]">
                <th className="py-1.5 pr-3 font-medium">Band</th>
                <th className="pr-3 font-medium">EARFCN</th>
                <th className="pr-3 font-medium">PCI</th>
                <th className="pr-3 font-medium">PLMN</th>
                <th className="pr-3 font-medium">Bandwidth</th>
                <th className="pr-3 font-medium">TAC</th>
                <th className="font-medium">Cell identity</th>
              </tr>
            </thead>
            <tbody>
              {analysis.cellDetails.map((c) => (
                <tr key={`${c.downlinkEarfcn}-${c.pci}`} className="border-b border-[var(--line)] last:border-b-0">
                  <td className="py-1.5 pr-3">
                    <span className="chip num" style={{ borderColor: palette.colorOf(`B${c.band}`) }}>
                      <span className="size-2 rounded-[2px]" style={{ background: palette.colorOf(`B${c.band}`) }} />
                      B{c.band}
                    </span>
                  </td>
                  <td className="num pr-3">{c.downlinkEarfcn}</td>
                  <td className="num pr-3">{c.pci}</td>
                  <td className="num pr-3">{c.plmn}</td>
                  <td className="num pr-3">{c.bandwidthMhz != null ? `${c.bandwidthMhz} MHz` : "—"}</td>
                  {/* TAC and the cell identity locate the phone, so they stay hidden while identifiers are masked. */}
                  <td className="num pr-3 text-[var(--text-3)]">{masked ? "hidden" : c.tac}</td>
                  <td className="num text-[var(--text-3)]">{masked ? "hidden" : c.cellIdentity ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

// ---------------------------------------------------------------------------------------------- what happened

function FindingRow({
  finding, analysis, palette, onJump, onOpenFlow, onShowOnTimeline,
}: {
  finding: Finding;
  analysis: CaptureAnalysis;
  palette: BandPalette;
  onJump: (tMs: number, event?: number) => void;
  onOpenFlow: (procedure?: string) => void;
  onShowOnTimeline: (tMs: number) => void;
}) {
  const Icon = ICONS[finding.kind] ?? Info;
  const text = findingText(finding, analysis);
  const pcell = finding.tMs == null ? null : pcellAt(analysis.journey, finding.tMs);
  const tone = finding.severity === "failure" ? "critical" : finding.severity === "warning" ? "warning" : null;

  return (
    <div
      className={cn(
        "group grid min-h-10 grid-cols-[72px_18px_minmax(0,1fr)_auto] items-center gap-2 border-b border-[var(--line)] px-3 last:border-b-0 hover:bg-[var(--surface-2)]",
        tone === "critical" && "shadow-[inset_2px_0_0_0_var(--critical)]",
        tone === "warning" && "shadow-[inset_2px_0_0_0_var(--warning)]",
      )}
    >
      <span className="num text-[11px] text-[var(--text-3)]">{finding.tMs == null ? "" : fmtSince(finding.tMs)}</span>
      <Icon
        className="size-[18px]"
        style={{ color: tone === "critical" ? "var(--critical)" : tone === "warning" ? "var(--warning)" : "var(--text-2)" }}
      />
      {finding.tMs == null ? (
        <span className="min-w-0 py-2 text-[13px]">{text}</span>
      ) : (
        <button
          className="min-w-0 truncate py-2 text-left text-[13px]"
          title={text}
          aria-label={`Move the cursor to ${fmtSince(finding.tMs)}: ${text}`}
          onClick={() => onJump(finding.tMs ?? 0, finding.event)}
        >
          {text}
        </button>
      )}
      <span className="flex shrink-0 items-center gap-1">
        {pcell && (
          <span className="chip num hidden max-w-36 truncate group-hover:hidden sm:inline-flex" style={{ borderColor: palette.colorOf(pcell.band) }}>
            {pcell.band} · PCI {pcell.cell.pci}
          </span>
        )}
        {finding.tMs != null && (
          <button
            className="btn-quiet hidden group-hover:inline-flex"
            title="Move the timeline cursor there and flash the moment"
            onClick={() => onShowOnTimeline(finding.tMs ?? 0)}
          >
            <Crosshair className="size-3.5" /> Show on timeline
          </button>
        )}
        {finding.event != null && (
          <button className="btn-quiet hidden group-hover:inline-flex" onClick={() => onOpenFlow(procedureForFinding(finding.kind))}>
            Open in call flow
          </button>
        )}
      </span>
    </div>
  );
}

// ------------------------------------------------------------------------------------------------- coverage
//
// The first thing a confused reader needs: what slice of time this actually is, how much of the ring buffer had
// already been overwritten by the time they pressed, and how to press better next time. Every number is the
// analysis's own; the advice is the one capture-timing constant the guide also uses, said in one line.

function CoverageCard({ analysis }: { analysis: CaptureAnalysis }) {
  const t = analysis.traceWindow;
  if (!t) {
    return (
      <section className="panel p-4" aria-labelledby="coverage">
        <h2 id="coverage" className="flex items-center gap-2 text-[13px] font-medium">
          <Clock className="size-4 text-[var(--text-3)]" /> What this trace covers
        </h2>
        <p className="mt-1.5 text-[13px] text-[var(--text-2)]">
          There is no modem trace in this file, so there is nothing to cover.
        </p>
      </section>
    );
  }

  const press = pressWindow(analysis);
  const window = press
    ? `This trace covers ${signedSeconds(press.from)} to ${signedSeconds(press.to)} around your press.`
    : `This trace is ${fmtDuration(analysis.durationMs)} long; the time you pressed the buttons is not in the file.`;
  const files = t.filesOnPhone
    ? `${t.filesKept.toLocaleString("en-US")} of ${t.filesOnPhone.toLocaleString("en-US")} trace files survived: ` +
      `${t.filesOverwritten.toLocaleString("en-US")} had already been overwritten by the modem, ` +
      `${t.filesMissing.toLocaleString("en-US")} ${t.filesMissing === 1 ? "is" : "are"} missing.`
    : "";

  return (
    <section className="panel p-4" aria-labelledby="coverage">
      <h2 id="coverage" className="flex items-center gap-2 text-[13px] font-medium">
        <Clock className="size-4 text-[var(--text-3)]" /> What this trace covers
      </h2>
      <p className="mt-1.5 text-[13px] leading-5 text-[var(--text)]">{window}</p>
      {files && <p className="mt-1 text-[13px] leading-5 text-[var(--text-2)]">{files}</p>}
      {t.filesOnPhone > 0 && (
        <div className="mt-2.5 flex h-2 overflow-hidden rounded-full bg-[var(--surface-2)]" aria-hidden="true">
          <span style={{ width: `${(t.filesKept / t.filesOnPhone) * 100}%`, background: "var(--text-2)" }} />
          <span style={{ width: `${(t.filesOverwritten / t.filesOnPhone) * 100}%`, background: "var(--line-strong)" }} />
          <span style={{ width: `${(t.filesMissing / t.filesOnPhone) * 100}%`, background: "var(--warning)" }} />
        </div>
      )}
      <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-[11px] text-[var(--text-3)]">
        <span className="flex items-center gap-1"><span className="h-2 w-3 rounded-[2px] bg-[var(--text-2)]" /> kept</span>
        <span className="flex items-center gap-1"><span className="h-2 w-3 rounded-[2px] bg-[var(--line-strong)]" /> overwritten</span>
        <span className="flex items-center gap-1"><span className="h-2 w-3 rounded-[2px] bg-[var(--warning)]" /> missing</span>
      </div>
      <p className="mt-3 border-t border-[var(--line)] pt-2 text-[13px] leading-5 text-[var(--text-2)]">
        <span className="font-medium text-[var(--text)]">Next time:</span> press the buttons first, do the thing
        you want captured 3–5 s later, and finish by about +12 s. The modem keeps only the last few seconds, so
        anything older than that{t.filesOverwritten > 0 ? ` — the ${t.filesOverwritten.toLocaleString("en-US")} overwritten files above — ` : " "}
        was already gone by the time you pressed.
      </p>
      <p className="mt-1.5 text-[11px] text-[var(--text-3)]">
        For a surprise event, press within 2–3 s of it. <Link to="/guide" className="text-[var(--action)] underline underline-offset-2">The guide has the full sequence</Link>.
      </p>
    </section>
  );
}

// --------------------------------------------------------------------------------------------- capture facts

function CaptureFacts({ analysis, onOpenRadio }: { analysis: CaptureAnalysis; onOpenRadio: (s?: RadioSection) => void }) {
  const profile = profileLine(analysis);
  const t = analysis.traceWindow;
  return (
    <section className="panel sticky top-[calc(var(--header-h)+var(--dock-h,0px)+56px)] p-4" aria-labelledby="facts">
      <h2 id="facts" className="text-[13px] font-medium">Capture facts</h2>

      <FactGroup title="Recording">
        <Fact k="Recorded" v={recordedAt(analysis)} />
        <Fact k="Trace window" v={traceWindowText(analysis)} />
        <Fact k="Length" v={fmtDuration(analysis.durationMs)} />
        <Fact
          k="Trace files"
          v={t ? `${t.filesKept} kept · ${t.filesOverwritten} overwritten · ${t.filesMissing} missing of ${t.filesOnPhone}` : "none"}
          meter={<TraceMeter analysis={analysis} />}
        />
      </FactGroup>

      <FactGroup title="Content">
        <Fact k="Plain records" v={`${analysis.records.toLocaleString("en-US")} · ${analysis.codes} codes`} />
        <Fact k="Decoded messages" v={analysis.events.length.toLocaleString("en-US")} />
        <Fact
          k="Encrypted"
          v={`${analysis.encrypted.records.toLocaleString("en-US")} · ${analysis.encrypted.codes} codes`}
          icon={<Lock className="size-3 text-[var(--text-3)]" />}
          onClick={() => onOpenRadio("Not available")}
        />
        <Fact k="CRC errors" v={analysis.crcErrors.toLocaleString("en-US")} />
      </FactGroup>

      <FactGroup title="Logging profile">
        <Fact k="Status" v={profile.text} icon={<StatusIcon severity={profile.severity} />} wrap />
        <Fact k="Installed" v={profileDates(analysis)} wrap />
      </FactGroup>

      {analysis.guide.needsAttention && (
        <Link to="/guide" className="btn-quiet mt-3 w-full justify-center">Open the guide</Link>
      )}
    </section>
  );
}

function FactGroup({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="mt-4">
      <h3 className="mb-1.5 text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">{title}</h3>
      <dl>{children}</dl>
    </div>
  );
}

function Fact({
  k, v, meter, icon, onClick, wrap,
}: {
  k: string;
  v: string;
  meter?: React.ReactNode;
  icon?: React.ReactNode;
  onClick?: () => void;
  /** A sentence rather than a number: it reads left-aligned instead of ragged-right. */
  wrap?: boolean;
}) {
  const value = (
    <span
      className={cn(
        "flex min-w-0 items-start gap-1 text-[13px]",
        wrap ? "justify-start text-left" : "num justify-end text-right",
      )}
    >
      {icon && <span className="mt-1 shrink-0">{icon}</span>}
      {v}
    </span>
  );
  return (
    // A fixed 132 px label column that never wraps (audit A29).
    <div className="grid grid-cols-[132px_minmax(0,1fr)] gap-3 border-b border-[var(--line)] py-1 last:border-b-0">
      <dt className="whitespace-nowrap text-xs text-[var(--text-3)]">{k}</dt>
      <dd className="min-w-0">
        {onClick ? (
          <button className="ml-auto block w-full underline-offset-4 hover:underline" onClick={onClick}>{value}</button>
        ) : (
          value
        )}
        {meter}
      </dd>
    </div>
  );
}

function TraceMeter({ analysis }: { analysis: CaptureAnalysis }) {
  const t = analysis.traceWindow;
  if (!t || !t.filesOnPhone) return null;
  const parts = [
    { w: (t.filesKept / t.filesOnPhone) * 100, color: "var(--text-2)" },
    { w: (t.filesOverwritten / t.filesOnPhone) * 100, color: "var(--line-strong)" },
    { w: (t.filesMissing / t.filesOnPhone) * 100, color: "var(--warning)" },
  ];
  return (
    <div
      className="mt-1 flex h-1.5 overflow-hidden rounded-full bg-[var(--surface-2)]"
      title={`${t.filesKept} kept, ${t.filesOverwritten} overwritten, ${t.filesMissing} missing`}
    >
      {parts.map((p, i) => (
        <span key={i} style={{ width: `${p.w}%`, background: p.color }} />
      ))}
    </div>
  );
}

// ------------------------------------------------------------------------------------------------- KPI tiles

function KpiTile({
  tile, analysis, onJump, onOpenFlow, onOpenRadio,
}: {
  tile: Tile;
  analysis: CaptureAnalysis;
  onJump: (tMs: number, event?: number) => void;
  onOpenFlow: (procedure?: string) => void;
  onOpenRadio: (section?: RadioSection) => void;
}) {
  const procedures = proceduresForTile(tile, analysis);
  const peakSeries =
    tile.id === "lteDlPeak" ? seriesOf(analysis, "lte_dl_phy_throughput")
    : tile.id === "nrDlPeak" ? seriesOf(analysis, "nr_dl_mac_throughput")
    : undefined;
  const peak = peakSeries ? peakPoint(peakSeries) : null;
  const open = () => {
    if (tile.id === "lteDlPeak") onOpenRadio("Downlink");
    else if (tile.id === "nrDlPeak") onOpenRadio("NR");
    else onOpenFlow(procedureNameForTile(tile));
  };
  const value = tile.id === "abnormalReleases" ? `${tile.value ?? "0"} lost of ${tile.attempts} connections` : tile.value ?? "—";

  // A group, not a button: the dots inside are buttons of their own, and a button cannot hold a button.
  return (
    <section className="panel flex min-h-[112px] flex-col p-3" aria-label={`${tile.title}: ${value}`}>
      <div className="flex items-center justify-between gap-2">
        <button className="min-w-0 truncate text-left text-xs text-[var(--text-2)] underline-offset-4 hover:underline" onClick={open}>
          {tile.title}
        </button>
        {tile.attempts > 0 && (
          <span className="num shrink-0 text-[11px] text-[var(--text-3)]">{tile.succeeded}/{tile.attempts}</span>
        )}
      </div>

      <p className="mt-1.5 flex items-baseline gap-2">
        <span className="num text-[20px] font-medium leading-7">{value}</span>
        {tile.attempts > 1 && <span className="text-[11px] text-[var(--text-3)]">median</span>}
      </p>

      <div className="mt-auto pt-2">
        {tile.attempts === 0 && peakSeries ? (
          <Sparkline series={peakSeries} durationMs={analysis.durationMs} onJump={onJump} />
        ) : (
          <AttemptDots procedures={procedures} analysis={analysis} onJump={onJump} />
        )}
        <p className="mt-1 truncate text-[11px] text-[var(--text-3)]">
          {tile.attempts === 0
            ? peak ? `peak at ${fmtSince(peak.tMs)}` : "no samples"
            : procedures.map((p) => fmtDuration(p.durationMs)).join(" · ") || "no attempts"}
        </p>
      </div>
    </section>
  );
}

/** Each attempt where it happened, on a mini axis of the whole capture. */
function AttemptDots({
  procedures, analysis, onJump,
}: {
  procedures: Procedure[];
  analysis: CaptureAnalysis;
  onJump: (tMs: number, event?: number) => void;
}) {
  const duration = Math.max(1, analysis.durationMs);
  return (
    <div className="relative h-4 border-t border-[var(--line)]">
      {procedures.map((p, i) => {
        // Where the attempt started, not how long it took — the old build plotted the duration by mistake.
        const tMs = analysis.events[p.first]?.sinceStartMs ?? 0;
        return (
          <button
            key={`${p.name}-${i}`}
            className={cn(
              "absolute top-[-3px] size-1.5 -translate-x-1/2 rounded-full border",
              p.outcome === "SUCCEEDED" && "border-[var(--good)] bg-[var(--good)]",
              p.outcome === "FAILED" && "border-[var(--critical)] bg-[var(--critical)]",
              p.outcome === "UNANSWERED" && "border-[var(--critical)] bg-transparent",
            )}
            style={{ left: `${(tMs / duration) * 100}%` }}
            title={`${fmtSince(tMs)} · ${fmtDuration(p.durationMs)} · ${p.outcome.toLowerCase()}`}
            aria-label={`${p.name} at ${fmtSince(tMs)}, ${fmtDuration(p.durationMs)}, ${p.outcome.toLowerCase()}`}
            onClick={() => onJump(tMs, p.first)}
          />
        );
      })}
    </div>
  );
}

/** For the peak tiles: the series per second across the whole capture, with the peak marked. */
function Sparkline({
  series, durationMs, onJump,
}: {
  series: PhySeries;
  durationMs: number;
  onJump: (tMs: number) => void;
}) {
  const samples = series.samples.filter((s) => s.value != null);
  const peak = peakPoint(series);
  if (!samples.length || !peak) return <div className="h-4 border-t border-[var(--line)]" />;
  const max = Math.max(1, peak.value);
  const duration = Math.max(1, durationMs);
  const points = samples
    .map((s) => `${((s.tMs / duration) * 100).toFixed(2)},${(16 - ((s.value ?? 0) / max) * 14).toFixed(2)}`)
    .join(" ");
  return (
    <button
      className="block w-full"
      aria-label={`${series.title}, peak ${peak.value} at ${fmtSince(peak.tMs)}. Move the cursor there.`}
      onClick={() => onJump(peak.tMs)}
    >
      <svg viewBox="0 0 100 16" preserveAspectRatio="none" className="h-4 w-full" aria-hidden="true">
        <polyline points={points} fill="none" stroke="var(--text-2)" strokeWidth="1" vectorEffect="non-scaling-stroke" />
        <circle cx={(peak.tMs / duration) * 100} cy={16 - 14} r="1.5" fill="var(--text)" vectorEffect="non-scaling-stroke" />
      </svg>
    </button>
  );
}

// ----------------------------------------------------------------------------------------------------- utils

/**
 * Whole seconds around the press, which is all the press time is good for. The modem's ring often starts before
 * the press, so the start can be negative and the sign has to survive.
 */
function traceWindowText(analysis: CaptureAnalysis): string {
  const press = pressWindow(analysis);
  if (!press) return "press time unknown";
  return `${signedSeconds(press.from)} to ${signedSeconds(press.to)} around press`;
}

function profileDates(analysis: CaptureAnalysis): string {
  const p = analysis.profile;
  if (!p.installDate || !p.removalDate) return "—";
  const days = p.lifetimeDays ?? Math.round((Date.parse(p.removalDate) - Date.parse(p.installDate)) / 86_400_000);
  const day = (iso: string) => new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  return `${day(p.installDate)}, removed ${day(p.removalDate)} (${days} days)`;
}

function procedureNameForTile(tile: Tile): string {
  switch (tile.id) {
    case "rrcSetup": return "RRC connection setup";
    case "serviceRequest": return "Service request";
    case "pdn": return "PDN connectivity";
    case "scgAdd": return "RRC reconfiguration";
    case "handover": return "Handover";
    case "attach": return "Attach";
    default: return tile.title;
  }
}

function procedureForFinding(kind: FindingKind): string | undefined {
  switch (kind) {
    case "handover": return "Handover";
    case "attach":
    case "reattach": return "Attach";
    case "imsPdn": return "PDN connectivity";
    case "endcAdded":
    case "scgPhyOutlived": return "RRC reconfiguration";
    default: return undefined;
  }
}

function proceduresForTile(tile: Tile, analysis: CaptureAnalysis): Procedure[] {
  const name = procedureNameForTile(tile);
  if (tile.id === "scgAdd") {
    // The SCG additions are the reconfigurations that carried the NR cell.
    return analysis.procedures.filter(
      (p) => p.name === "RRC reconfiguration" && analysis.events[p.first]?.rat === "NR",
    );
  }
  return analysis.procedures.filter((p) => p.name === name);
}

function peakPoint(series: PhySeries): { tMs: number; value: number } | null {
  return series.samples.reduce<{ tMs: number; value: number } | null>((best, s) => {
    if (s.value == null) return best;
    return !best || s.value > best.value ? { tMs: s.tMs, value: s.value } : best;
  }, null);
}
