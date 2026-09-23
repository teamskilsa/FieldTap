// Radio: small multiples on one shared time axis, plus the per-carrier grid, the antenna and RACH summaries, and
// the honest "Not available" panel.
//
// Nothing here hard-codes a capture fact (audit A13): antennas come from phySummary, bandwidth from cellDetails,
// bands from the journey. Every column in the carriers grid is filtered to its own carrier or cell (A15).
import { useEffect, useMemo, useState } from "react";
import { Ban, CircleCheck, Clock, Lock, SearchX, XCircle } from "lucide-react";
import {
  AllocationMark, BarMark, Chart, CrosshairProvider, decimate, LineMark, ScatterMark, StackedMark, StepMark, type Scale,
} from "@/components/capture/charts";
import { fmtMetric, fmtSince, fmtValue, rsrpQuality } from "@/lib/analysis/format";
import { SEQUENTIAL, useBandPalette, type BandPalette } from "@/lib/analysis/palette";
import { activeCells, sampleAt, seriesOf } from "@/lib/analysis/select";
import type {
  AvailabilityStatus, CaptureAnalysis, JourneyCell, PhyMetric, PhySample, PhySeries,
} from "@engine/types";
import { cn } from "@/lib/utils";

export type RadioSection =
  | "Signal" | "Neighbours" | "Downlink" | "Uplink" | "CSI" | "NR" | "Carriers" | "Antennas" | "RACH" | "Not available";

const SECTIONS: RadioSection[] = [
  "Signal", "Neighbours", "Downlink", "Uplink", "CSI", "NR", "Carriers", "Antennas", "RACH", "Not available",
];

/** Modulation order is ordinal, so it takes the sequential ramp, never band colours (audit A23). */
const MODS = ["QPSK", "16QAM", "64QAM", "256QAM"] as const;
const MOD_COLOR: Record<string, string> = {
  QPSK: SEQUENTIAL[0] as string,
  "16QAM": SEQUENTIAL[1] as string,
  "64QAM": SEQUENTIAL[2] as string,
  "256QAM": SEQUENTIAL[3] as string,
};

/**
 * Series that are a fact about the cell rather than something that varies usefully over time. A 132 px line of
 * "band = 2" says nothing; the same number reads properly in the Carriers grid and the Antennas panel, so they
 * are shown there and skipped here.
 */
const SHOWN_ELSEWHERE = new Set<PhyMetric>([
  "lte_band",
  "lte_dl_bandwidth_prb",
  "lte_tx_antennas_mib",
  "lte_rx_antennas_measured",
  // Measured per serving cell rather than plotted: the Antennas section shows them with their source.
  "lte_pdsch_tx_antennas",
  "lte_pdsch_rx_antennas",
  // The neighbour list has its own section, and its RSRP is drawn on the serving-cell chart in Signal.
  "lte_neighbour_rsrp_intra",
  "lte_neighbour_rsrq_intra",
  "lte_neighbour_margin",
  // Drawn inside another chart: the allocation as a strip, the chain limit as a line on the power chart.
  "lte_dl_prb_allocation",
  "lte_fed_tx_limit",
]);

interface SectionProps {
  analysis: CaptureAnalysis;
  palette: BandPalette;
  view: [number, number];
  cursorMs: number;
  onCursor: (ms: number) => void;
  onView: (v: [number, number]) => void;
}

export function RadioTab({
  analysis, cursorMs, view, onCursor, onView, initialSection, onSection,
}: {
  analysis: CaptureAnalysis;
  cursorMs: number;
  view: [number, number];
  onCursor: (ms: number) => void;
  onView: (v: [number, number]) => void;
  initialSection?: RadioSection;
  /** Told upward so `?section=` in the URL follows the rail (deep links). */
  onSection?: (s: RadioSection) => void;
}) {
  const [section, setSectionRaw] = useState<RadioSection>(initialSection ?? "Signal");
  const setSection = (s: RadioSection) => {
    setSectionRaw(s);
    onSection?.(s);
  };
  useEffect(() => {
    if (initialSection && initialSection !== section) setSectionRaw(initialSection);
    // Only a new instruction from the URL or a caller moves the rail; the reader's own clicks are not re-applied.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialSection]);
  const palette = useBandPalette(analysis);
  const props: SectionProps = { analysis, palette, view, cursorMs, onCursor, onView };
  const hasNr = analysis.journey.cells.some((c) => c.lane === "pscell");

  return (
    <div className="grid min-w-0 gap-4 lg:grid-cols-[180px_minmax(0,1fr)]">
      <nav
        className="-mx-4 flex gap-1 overflow-x-auto px-4 pb-1 lg:mx-0 lg:block lg:space-y-0.5 lg:px-0"
        aria-label="Radio sections"
      >
        {SECTIONS.map((s) => (
          <button
            key={s}
            onClick={() => setSection(s)}
            aria-current={section === s ? "true" : undefined}
            className={cn(
              "flex h-8 shrink-0 items-center gap-2 rounded-[6px] px-2.5 text-[13px] transition-colors duration-[120ms] lg:w-full lg:justify-between",
              section === s ? "bg-[var(--surface-2)] font-medium text-[var(--text)]" : "text-[var(--text-3)] hover:text-[var(--text)]",
            )}
          >
            {s}
            <span className="num text-[11px] text-[var(--text-3)]">{countOf(analysis, s, cursorMs)}</span>
          </button>
        ))}
      </nav>

      <section className="min-w-0 space-y-2" aria-label={`${section} charts`}>
        <CrosshairProvider>
          {section === "Signal" && <SignalSection {...props} />}
          {section === "Neighbours" && <NeighbourSection {...props} onCursor={onCursor} />}
          {section === "Downlink" && <DownlinkSection {...props} />}
          {section === "Uplink" && <UplinkSection {...props} />}
          {section === "CSI" && <CsiSection {...props} />}
          {section === "NR" && (hasNr ? <NrSection {...props} /> : <Empty>No 5G NR leg in this capture.</Empty>)}
        </CrosshairProvider>
        {section === "Carriers" && <CarriersGrid analysis={analysis} palette={palette} cursorMs={cursorMs} />}
        {section === "Antennas" && <AntennaPanel analysis={analysis} cursorMs={cursorMs} />}
        {section === "RACH" && <RachPanel analysis={analysis} onCursor={onCursor} />}
        {section === "Not available" && <NotAvailablePanel analysis={analysis} />}
      </section>
    </div>
  );
}

// --------------------------------------------------------------------------------------------------- sections

function SignalSection({ analysis, palette, view, cursorMs, onCursor, onView }: SectionProps) {
  const frame = { analysis, palette, view, cursorMs, onCursor, onView };
  const all = sectionSeries(analysis, "signal");
  const perRx = all.find((s) => s.perIndexSeries);
  const rest = all.filter((s) => !s.perIndexSeries);
  const rxAt = sampleAt(perRx, cursorMs);
  const rxCount = Math.max(1, ...(perRx?.samples ?? []).map((s) => s.perIndex?.length ?? 0));
  const serving = seriesOf(analysis, "lte_rsrp_filtered");
  const neighbours = seriesOf(analysis, "lte_neighbour_rsrp_intra");

  return (
    <>
      {perRx && (
        <Chart
          {...frame}
          title="RSRP per receive antenna"
          unit="dBm"
          series={perRx}
          valueAtCursor={rxAt?.perIndex?.map((v) => fmtValue(v, perRx.unit)).join(" / ") ?? "—"}
          values={thin(perRx.samples ?? [], 4000).flatMap((s) => (s.perIndex ?? []).filter((v): v is number => v != null))}
          note={
            <div className="flex flex-wrap gap-2 pb-1">
              {Array.from({ length: rxCount }, (_, i) => (
                <span key={i} className="flex items-center gap-1 text-[11px] text-[var(--text-3)]">
                  <span className="h-0.5 w-3" style={{ background: SEQUENTIAL[i % SEQUENTIAL.length] }} /> Rx{i}
                </span>
              ))}
            </div>
          }
        >
          {(scale) => (
            <g>
              {Array.from({ length: rxCount }, (_, i) => (
                <LineMark
                  key={i}
                  scale={scale}
                  stroke={SEQUENTIAL[i % SEQUENTIAL.length] as string}
                  points={thin(windowed(perRx, view)).map((s) => ({ t: s.tMs, v: s.perIndex?.[i] ?? null }))}
                />
              ))}
            </g>
          )}
        </Chart>
      )}
      {neighbours && serving && (
        <Chart
          {...frame}
          title="Serving cell and its intra-frequency neighbours"
          unit="dBm"
          series={neighbours}
          valueAtCursor={valueText(sampleAt(serving, cursorMs), "dBm")}
          values={[...serving.samples, ...neighbours.samples].map((s) => s.value ?? 0)}
          note={
            <p className="pb-1 text-[11px] text-[var(--text-3)]">
              The line is the serving cell (0xB193); each dot is a neighbour this record measured, by PCI. Most of
              them are measured by nothing else in the capture.
            </p>
          }
        >
          {(scale) => (
            <g>
              <ScatterMark
                scale={scale}
                points={thin(windowed(neighbours, view), 2500).map((s) => ({
                  t: s.tMs,
                  v: s.value,
                  fill: pciColor(s.pci ?? 0),
                }))}
              />
              <LineMark
                scale={scale}
                stroke="var(--text)"
                points={decimate(windowed(serving, view)).map((s) => ({ t: s.tMs, v: s.value }))}
              />
            </g>
          )}
        </Chart>
      )}
      {rest.map((series, i) => (
        <Simple key={series.metric} {...frame} series={series} showAxis={i === rest.length - 1} />
      ))}
    </>
  );
}

/**
 * The neighbour list and the handover margin (0xB179): the answer to "why didn't it hand over". The margin is the
 * neighbour's RSRP less the serving cell's in the same record, so above 0 dB the neighbour was the stronger cell -
 * and if the phone stayed anyway, the network's offsets and time-to-trigger are the reason.
 */
function NeighbourSection({ analysis, palette, view, cursorMs, onCursor, onView }: SectionProps) {
  const frame = { analysis, palette, view, cursorMs, onCursor, onView };
  const margin = seriesOf(analysis, "lte_neighbour_margin");
  const cells = analysis.phySummary.intraFreqNeighbours ?? [];
  if (!cells.length || !margin) {
    return <Empty>No intra-frequency neighbour measurements in this capture (0xB179).</Empty>;
  }
  const stronger = cells.filter((c) => c.marginBestDb > 0);
  return (
    <div className="space-y-2">
      <Chart
        {...frame}
        title="Handover margin: each neighbour against the serving cell"
        unit="dB"
        series={margin}
        showAxis
        valueAtCursor={valueText(sampleAt(margin, cursorMs), "dB")}
        rules={[{ value: 0, label: "as strong as the serving cell" }]}
        note={
          <p className="pb-1 text-[11px] text-[var(--text-3)]">
            Measured inside one record, so no clock skew: above the line the neighbour was stronger than the cell
            the phone was on.
          </p>
        }
      >
        {(scale) => (
          <ScatterMark
            scale={scale}
            points={thin(windowed(margin, view), 2500).map((s) => ({ t: s.tMs, v: s.value, fill: pciColor(s.pci ?? 0) }))}
          />
        )}
      </Chart>
      <section className="panel overflow-x-auto">
        <h3 className="border-b border-[var(--line)] px-3 py-2 text-[13px] font-medium">
          Neighbours measured <span className="num text-[var(--text-3)]">{cells.length}</span>
          <span className="chip num ml-2">0xB179 v56</span>
          {stronger.length > 0 && (
            <span className="ml-2 text-[11px] font-normal text-[var(--text-3)]">
              {stronger.length} reached or passed the serving cell
            </span>
          )}
        </h3>
        <table className="w-full min-w-[620px] text-[13px]">
          <thead>
            <tr className="border-b border-[var(--line)] text-[11px] uppercase tracking-[0.02em] text-[var(--text-3)]">
              <th className="px-3 py-1.5 text-left font-medium">EARFCN</th>
              <th className="py-1.5 text-left font-medium">PCI</th>
              <th className="py-1.5 text-left font-medium">Best RSRP</th>
              <th className="py-1.5 text-left font-medium">Median RSRP</th>
              <th className="py-1.5 text-left font-medium">Median RSRQ</th>
              <th className="py-1.5 text-left font-medium">Best margin</th>
              <th className="py-1.5 text-left font-medium">Median margin</th>
              <th className="py-1.5 text-left font-medium">Measurements</th>
              <th className="py-1.5 text-left font-medium">First seen</th>
            </tr>
          </thead>
          <tbody>
            {cells.map((c) => (
              <tr key={`${c.earfcn}-${c.pci}`} className="border-b border-[var(--line)] last:border-b-0 hover:bg-[var(--surface-2)]">
                <td className="num px-3 py-1.5">{c.earfcn}</td>
                <td className="num py-1.5">
                  <span className="inline-flex items-center gap-1.5">
                    <span className="size-2 rounded-full" style={{ background: pciColor(c.pci) }} />
                    {c.pci}
                  </span>
                </td>
                <td className="num py-1.5">{fmtMetric(c.rsrpBestDbm, "dBm")}</td>
                <td className="num py-1.5 text-[var(--text-3)]">{fmtMetric(c.rsrpMedianDbm, "dBm")}</td>
                <td className="num py-1.5 text-[var(--text-3)]">{fmtMetric(c.rsrqMedianDb, "dB")}</td>
                <td className={cn("num py-1.5", c.marginBestDb > 0 && "text-[var(--warning)]")}>
                  {signedDb(c.marginBestDb)}
                </td>
                <td className="num py-1.5 text-[var(--text-3)]">{signedDb(c.marginMedianDb)}</td>
                <td className="num py-1.5">
                  {c.measurements}
                  {c.onlySource && <span className="chip ml-1.5">only source</span>}
                </td>
                <td className="num py-1.5">
                  <button className="underline-offset-2 hover:underline" onClick={() => onCursor(c.firstMs)}>
                    {fmtSince(c.firstMs)}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="px-3 py-2 text-[11px] text-[var(--text-3)]">
          "Only source" means no other record in this capture measured that cell. The margin is the neighbour's RSRP
          less the serving cell's in the same record; a positive margin with no handover is the network's own
          offsets and time-to-trigger at work.
        </p>
      </section>
    </div>
  );
}

function DownlinkSection({ analysis, palette, view, cursorMs, onCursor, onView }: SectionProps) {
  const frame = { analysis, palette, view, cursorMs, onCursor, onView };
  const mcs = seriesOf(analysis, "lte_dl_mcs");
  const bler = seriesOf(analysis, "lte_dl_bler");
  const tput = seriesOf(analysis, "lte_dl_phy_throughput");
  const mix = useMemo(() => modulationMix(mcs, view), [mcs, view]);
  const carriers = useMemo(() => carrierKeys(tput, palette), [palette, tput]);
  const rest = sectionSeries(analysis, "downlink").filter(
    (s) => !["lte_dl_mcs", "lte_dl_bler", "lte_dl_phy_throughput"].includes(s.metric),
  );
  const allocation = seriesOf(analysis, "lte_dl_prb_allocation");
  const bandwidthPrb = Math.max(
    6,
    ...(seriesOf(analysis, "lte_dl_bandwidth_prb")?.samples.map((s) => s.value ?? 0) ?? []),
    ...(allocation?.samples.map((s) => (s.mask?.length ?? 0) * 32) ?? []),
  );

  return (
    <>
      {mcs && (
        <Chart
          {...frame}
          title="Downlink MCS by modulation"
          unit="index"
          series={mcs}
          // 0-31, so retransmission MCS 29-31 is not clipped off the top (audit A24).
          domain={[0, 31]}
          valueAtCursor={valueText(sampleAt(mcs, cursorMs), "")}
          note={<ModLegend />}
        >
          {(scale) => (
            <ScatterMark
              scale={scale}
              points={decimate(windowed(mcs, view)).map((s) => ({
                t: s.tMs,
                v: s.value,
                fill: MOD_COLOR[s.tag ?? ""] ?? "var(--text-3)",
                hollow: s.tag === "retx",
              }))}
            />
          )}
        </Chart>
      )}
      {mix.length > 0 && (
        <Chart
          {...frame}
          title="Modulation mix per second"
          unit="%"
          {...(mcs ? { series: mcs } : {})}
          domain={[0, 100]}
          valueAtCursor="100%"
          note={<ModLegend />}
        >
          {(scale) => (
            <StackedMark
              scale={scale}
              buckets={mix}
              keys={[...MODS]}
              colorOf={(k) => MOD_COLOR[k] ?? "var(--text-3)"}
            />
          )}
        </Chart>
      )}
      {allocation && (
        <Chart
          {...frame}
          title="Which resource blocks the scheduler gave this phone"
          unit="PRB index"
          series={allocation}
          domain={[0, bandwidthPrb]}
          valueAtCursor={valueText(sampleAt(allocation, cursorMs), "PRB")}
          note={
            <p className="pb-1 text-[11px] text-[var(--text-3)]">
              One column per logged subframe, filled at the allocated resource blocks - not just how many, which
              ones. Decoded from the PDSCH demapper configuration, 20 subframes per record.
            </p>
          }
        >
          {(scale) => (
            <AllocationMark
              scale={scale}
              view={view}
              fill="var(--seq-300)"
              columns={thin(windowed(allocation, view), 3000).map((s) => ({ t: s.tMs, mask: s.mask ?? [] }))}
            />
          )}
        </Chart>
      )}
      {rest.map((series) => (
        <Simple key={series.metric} {...frame} series={series} />
      ))}
      {bler && (
        <Chart
          {...frame}
          title="Downlink block error rate"
          unit="%"
          series={bler}
          domain={[0, Math.max(20, ...bler.samples.map((s) => s.value ?? 0))]}
          valueAtCursor={valueText(sampleAt(bler, cursorMs), "%")}
          rules={[{ value: 10, label: "10% target" }]}
        >
          {(scale) => (
            <BarMark scale={scale} fill="var(--text-2)" points={decimate(windowed(bler, view)).map((s) => ({ t: s.tMs, v: s.value }))} />
          )}
        </Chart>
      )}
      {tput && (
        <Chart
          {...frame}
          title="Downlink PHY throughput, stacked by carrier"
          unit="Mbit/s"
          series={tput}
          showAxis
          valueAtCursor={valueText(sampleAt(tput, cursorMs), "Mbit/s")}
          values={tput.samples.map((s) => s.value ?? 0)}
          note={
            <div className="flex flex-wrap gap-2 pb-1">
              {carriers.map((c) => (
                <span key={c.key} className="flex items-center gap-1 text-[11px] text-[var(--text-3)]">
                  <span className="size-2 rounded-[2px]" style={{ background: c.color }} /> {c.label}
                </span>
              ))}
            </div>
          }
        >
          {(scale) => (
            <StackedMark
              scale={scale}
              buckets={stackByCarrier(tput, view)}
              keys={carriers.map((c) => c.key)}
              colorOf={(k) => carriers.find((c) => c.key === k)?.color ?? "var(--text-2)"}
              gap={1}
            />
          )}
        </Chart>
      )}
      <MacAccountingPanel analysis={analysis} />
    </>
  );
}

/**
 * MAC-level downlink accounting (0xB063): useful bytes against wasted ones, and signalling against user data. It is
 * never the total - the walk over the PDCP tails reaches about 80% of the transport blocks the records declare -
 * so the coverage is stated on the panel and 0xB173 stays the throughput source.
 */
function MacAccountingPanel({ analysis }: { analysis: CaptureAnalysis }) {
  const mac = analysis.phySummary.macDl;
  if (!mac) return null;
  const byKind = (kinds: string[]) => mac.channels.filter((c) => kinds.includes(c.kind)).reduce((n, c) => n + c.bytes, 0);
  const data = byKind(["data"]), signalling = byKind(["signalling", "broadcast"]), control = byKind(["control", "other"]);
  const total = Math.max(1, data + signalling + control);
  const bars: { label: string; bytes: number; color: string }[] = [
    { label: "User data", bytes: data, color: "var(--seq-400)" },
    { label: "Signalling", bytes: signalling, color: "var(--seq-200)" },
    { label: "Control and unattributed", bytes: control, color: "var(--line-strong)" },
  ];
  return (
    <section className="panel p-4">
      <h3 className="flex flex-wrap items-center gap-2 text-[13px] font-medium">
        What reached the MAC
        <span className="chip num">0xB063 v50</span>
        <span className="chip" title="The walk over the PDCP tails reaches about 80% of the declared transport blocks.">
          partial coverage
        </span>
      </h3>
      <p className="mt-1 text-xs text-[var(--text-3)]">
        {`${mac.walkedBlocks.toLocaleString("en-US")} of ${mac.declaredBlocks.toLocaleString("en-US")} declared transport blocks were walked (${
          (mac.coverageShare * 100).toFixed(0)
        }% coverage), so every byte below is a floor, not a total. Throughput comes from 0xB173, above.`}
      </p>
      <div className="mt-3 grid gap-4 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div>
          <p className="num text-[20px] font-medium leading-7">
            {fmtBytes(mac.bytes)}
            <span className="ml-2 text-[13px] font-normal text-[var(--text-3)]">reached the MAC</span>
          </p>
          <p className="num mt-1 text-[13px] text-[var(--text-3)]">
            {`${fmtBytes(mac.paddingBytes)} of it was padding (${(mac.paddingShare * 100).toFixed(1)}% wasted grant)`}
          </p>
          <p className="num mt-1 text-[13px] text-[var(--text-3)]">
            {mac.timingAdvanceCommands === 0
              ? "No timing-advance commands"
              : `${mac.timingAdvanceCommands} timing-advance commands (the record carries no value for them)`}
          </p>
        </div>
        <div>
          <div className="flex h-3 overflow-hidden rounded-[3px]">
            {bars.map((b) => (
              <div key={b.label} style={{ width: `${(b.bytes / total) * 100}%`, background: b.color }} title={`${b.label}: ${fmtBytes(b.bytes)}`} />
            ))}
          </div>
          <div className="mt-2 space-y-1">
            {bars.map((b) => (
              <div key={b.label} className="flex items-center gap-2 text-[11px] text-[var(--text-3)]">
                <span className="size-2 rounded-[2px]" style={{ background: b.color }} />
                {b.label}
                <span className="num ml-auto">{fmtBytes(b.bytes)}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
      <div className="-mx-4 mt-3 overflow-x-auto px-4">
      <table className="w-full min-w-[420px] text-[13px]">
        <thead>
          <tr className="border-b border-[var(--line)] text-[11px] uppercase tracking-[0.02em] text-[var(--text-3)]">
            <th className="py-1.5 text-left font-medium">Channel</th>
            <th className="py-1.5 text-left font-medium">LCID</th>
            <th className="py-1.5 text-left font-medium">Bytes</th>
            <th className="py-1.5 text-left font-medium">SDUs</th>
          </tr>
        </thead>
        <tbody>
          {mac.channels.map((c) => (
            <tr key={c.lcid} className="border-b border-[var(--line)] last:border-b-0">
              <td className="py-1.5">{c.name}</td>
              <td className="num py-1.5 text-[var(--text-3)]">{c.lcid}</td>
              <td className="num py-1.5">{fmtBytes(c.bytes)}</td>
              <td className="num py-1.5 text-[var(--text-3)]">{c.sdus.toLocaleString("en-US")}</td>
            </tr>
          ))}
        </tbody>
      </table>
      </div>
    </section>
  );
}

function UplinkSection({ analysis, palette, view, cursorMs, onCursor, onView }: SectionProps) {
  const frame = { analysis, palette, view, cursorMs, onCursor, onView };
  const power = seriesOf(analysis, "lte_pusch_tx_power_required");
  const tput = seriesOf(analysis, "lte_ul_phy_throughput");
  const fedPower = seriesOf(analysis, "lte_fed_tx_power");
  const fedLimit = seriesOf(analysis, "lte_fed_tx_limit");
  const rest = sectionSeries(analysis, "uplink").filter(
    (s) => !["lte_pusch_tx_power_required", "lte_ul_phy_throughput", "lte_fed_tx_power", "lte_pa_gain_state"].includes(s.metric),
  );
  return (
    <>
      <TransmitLimitedPanel analysis={analysis} />
      {power && (
        <Chart
          {...frame}
          title="PUSCH transmit power required"
          unit="dBm"
          series={power}
          valueAtCursor={valueText(sampleAt(power, cursorMs), "dBm")}
          rules={[{ value: 23, label: "23 dBm, typical Pcmax" }]}
        >
          {(scale) => (
            <>
              {/* Above the device maximum the phone is power-limited: shade it rather than colour the line. */}
              <rect
                x={scale.x(view[0])}
                y={scale.y(scale.domain[1])}
                width={scale.plotW}
                height={Math.max(0, scale.y(23) - scale.y(scale.domain[1]))}
                fill="color-mix(in oklab, var(--warning) 12%, transparent)"
              />
              <LineMark scale={scale} stroke="var(--text-2)" points={decimate(windowed(power, view)).map((s) => ({ t: s.tMs, v: s.value }))} />
            </>
          )}
        </Chart>
      )}
      {fedPower && (
        <Chart
          {...frame}
          title="Front-end transmit power, per chain, against the chain's own limit"
          unit="dBm"
          series={fedPower}
          valueAtCursor={valueText(sampleAt(fedPower, cursorMs), "dBm")}
          values={[...fedPower.samples, ...(fedLimit?.samples ?? [])].map((s) => s.value ?? 0)}
          note={
            <div className="flex flex-wrap gap-2 pb-1 text-[11px] text-[var(--text-3)]">
              {chainLegend(analysis).map((c) => (
                <span key={c.chain} className="flex items-center gap-1">
                  <span className="size-2 rounded-full" style={{ background: c.color }} /> {c.chain}
                </span>
              ))}
              <span className="flex items-center gap-1">
                <span className="h-0.5 w-3 bg-[var(--warning)]" /> the chain's logged limit
              </span>
            </div>
          }
        >
          {(scale) => (
            <g>
              {fedLimit && (
                <LineMark
                  scale={scale}
                  stroke="var(--warning)"
                  points={thin(windowed(fedLimit, view), 2000).map((s) => ({ t: s.tMs, v: s.value }))}
                />
              )}
              <ScatterMark
                scale={scale}
                points={thin(windowed(fedPower, view), 3000).map((s) => ({
                  t: s.tMs,
                  v: s.value,
                  fill: chainColor(s.tag ?? ""),
                }))}
              />
            </g>
          )}
        </Chart>
      )}
      {rest.map((series) => (
        <Simple key={series.metric} {...frame} series={series} />
      ))}
      {tput && (
        <Chart
          {...frame}
          title="UL scheduled throughput"
          unit="Mbit/s"
          series={tput}
          showAxis
          valueAtCursor={valueText(sampleAt(tput, cursorMs), "Mbit/s")}
        >
          {(scale) => (
            <BarMark scale={scale} fill="var(--text-2)" points={decimate(windowed(tput, view)).map((s) => ({ t: s.tMs, v: s.value }))} />
          )}
        </Chart>
      )}
    </>
  );
}

/**
 * Is the phone transmit-limited, and on which chain (0x184C)? An uplink-limited phone at the cell edge is the most
 * common cause of "full bars, nothing works", and nothing else FieldTap decodes says it. The power and the limit are
 * the front end's own, logged at its own instants, so the wording is "at or above its logged limit" rather than
 * "capped", and the numbers carry medium confidence.
 */
function TransmitLimitedPanel({ analysis }: { analysis: CaptureAnalysis }) {
  const front = analysis.phySummary.uplinkFrontEnd;
  if (!front || front.liveSamples === 0) return null;
  const share = front.atLimitShare;
  const limited = share >= 0.25;
  const live = front.chains.filter((c) => c.liveSamples > 0).sort((a, b) => b.liveSamples - a.liveSamples);
  return (
    <section className="panel p-4">
      <h3 className="flex flex-wrap items-center gap-2 text-[13px] font-medium">
        Transmit power at the front end
        <span className="chip num">0x184C v17</span>
        <span className="chip" title="The front end's own power, a different quantity from the PUSCH power the network asked for.">front-end</span>
        <span className="chip border-[var(--warning)]/45" title="Decoded with a record layout that still has some uncertainty.">medium</span>
      </h3>
      <p className="num mt-1 text-[20px] font-medium leading-7">
        <span className={limited ? "text-[var(--warning)]" : undefined}>
          {limited ? "Transmit-limited" : "Not transmit-limited"}
        </span>
        <span className="ml-2 text-[13px] font-normal text-[var(--text-3)]">
          {`${(share * 100).toFixed(0)}% of ${front.liveSamples.toLocaleString("en-US")} transmitting samples sat at or above the chain's own limit`}
        </span>
      </p>
      <p className="mt-1 text-[13px] text-[var(--text-3)]">
        {front.liveChain
          ? `Transmitting on chain ${front.liveChain}${live.length > 1 ? `, with ${live.length - 1} more chain${live.length > 2 ? "s" : ""} active` : ""}.`
          : "No chain was transmitting."}
      </p>
      <div className="-mx-4 mt-3 overflow-x-auto px-4">
      <table className="w-full min-w-[640px] text-[13px]">
        <thead>
          <tr className="border-b border-[var(--line)] text-[11px] uppercase tracking-[0.02em] text-[var(--text-3)]">
            <th className="py-1.5 text-left font-medium">Chain</th>
            <th className="py-1.5 text-left font-medium">Transmitting</th>
            <th className="py-1.5 text-left font-medium">Median</th>
            <th className="py-1.5 text-left font-medium">Peak</th>
            <th className="py-1.5 text-left font-medium">Limit</th>
            <th className="py-1.5 text-left font-medium">At the limit</th>
            <th className="py-1.5 text-left font-medium">PA gain states</th>
          </tr>
        </thead>
        <tbody>
          {front.chains.map((c) => (
            <tr key={c.chain} className={cn("border-b border-[var(--line)] last:border-b-0", c.liveSamples === 0 && "text-[var(--text-3)]")}>
              <td className="num py-1.5">
                <span className="inline-flex items-center gap-1.5">
                  <span className="size-2 rounded-full" style={{ background: chainColor(`chain ${c.chain}`) }} />
                  {c.chain}
                  {c.chain === front.liveChain && <span className="chip ml-1">transmitting</span>}
                </span>
              </td>
              <td className="num py-1.5">{c.liveSamples === 0 ? "off" : `${c.liveSamples.toLocaleString("en-US")} of ${c.samples.toLocaleString("en-US")}`}</td>
              <td className="num py-1.5">{c.liveSamples === 0 ? "—" : fmtMetric(c.medianPowerDbm, "dBm")}</td>
              <td className="num py-1.5">{c.liveSamples === 0 ? "—" : fmtMetric(c.maxPowerDbm, "dBm")}</td>
              <td className="num py-1.5">{c.limitDbm == null ? "—" : fmtMetric(c.limitDbm, "dBm")}</td>
              <td className="num py-1.5">
                {c.liveSamples === 0 ? "—" : `${((c.atLimitSamples / c.liveSamples) * 100).toFixed(0)}%`}
              </td>
              <td className="num py-1.5 text-[var(--text-3)]">{c.gainStates.length ? c.gainStates.join(", ") : "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
      </div>
      <p className="mt-2 text-[11px] text-[var(--text-3)]">
        {front.source}. The PUSCH power the network asked for is the chart below this one; a best fit between the two
        leaves about 3.8 dB, which is why they are shown side by side rather than as one number.
      </p>
    </section>
  );
}

function CsiSection({ analysis, palette, view, cursorMs, onCursor, onView }: SectionProps) {
  const frame = { analysis, palette, view, cursorMs, onCursor, onView };
  const all = sectionSeries(analysis, "csi");
  return (
    <>
      {all.map((series, i) => (
        <Simple
          key={series.metric}
          {...frame}
          series={series}
          {...(series.metric.includes("cqi") ? { domain: [0, 15] as [number, number] } : {})}
          {...(series.metric === "lte_ri" ? { domain: [0, 4] as [number, number], step: true } : {})}
          showAxis={i === all.length - 1}
        />
      ))}
    </>
  );
}

function NrSection({ analysis, palette, view, cursorMs, onCursor, onView }: SectionProps) {
  const frame = { analysis, palette, view, cursorMs, onCursor, onView };
  const rsrp = seriesOf(analysis, "nr_ss_rsrp");
  const mcs = seriesOf(analysis, "nr_dl_mcs");
  const tput = seriesOf(analysis, "nr_dl_mac_throughput");
  const rest = sectionSeries(analysis, "nr").filter(
    (s) => !["nr_ss_rsrp", "nr_dl_mcs", "nr_dl_mac_throughput"].includes(s.metric),
  );
  return (
    <>
      {rsrp && <Simple {...frame} series={rsrp} />}
      {mcs && <Simple {...frame} series={mcs} domain={[0, 31]} scatter />}
      {rest.map((series) => (
        <Simple key={series.metric} {...frame} series={series} />
      ))}
      {tput && (
        <Chart
          {...frame}
          // The series is MAC, not PHY, and the label says so (audit A24).
          title="NR DL MAC throughput per second"
          unit="Mbit/s"
          series={tput}
          showAxis
          valueAtCursor={valueText(sampleAt(tput, cursorMs), "Mbit/s")}
        >
          {(scale) => (
            <BarMark scale={scale} fill="var(--band-nr)" points={decimate(windowed(tput, view)).map((s) => ({ t: s.tMs, v: s.value }))} />
          )}
        </Chart>
      )}
    </>
  );
}

/** A one-series chart: a line, a step or a scatter, whichever suits the metric. */
function Simple({
  analysis, palette, view, cursorMs, onCursor, onView, series, domain, showAxis, step, scatter,
}: SectionProps & {
  series: PhySeries;
  domain?: [number, number];
  showAxis?: boolean;
  step?: boolean;
  scatter?: boolean;
}) {
  const points = decimate(windowed(series, view)).map((s) => ({ t: s.tMs, v: s.value }));
  return (
    <Chart
      analysis={analysis}
      palette={palette}
      view={view}
      cursorMs={cursorMs}
      onCursor={onCursor}
      onView={onView}
      title={series.title}
      unit={series.unit}
      series={series}
      {...(domain ? { domain } : {})}
      {...(showAxis ? { showAxis } : {})}
      valueAtCursor={valueText(sampleAt(series, cursorMs), series.unit)}
    >
      {(scale: Scale) =>
        scatter ? (
          <ScatterMark scale={scale} points={points.map((p) => ({ ...p, fill: "var(--seq-300)" }))} />
        ) : step ? (
          <StepMark scale={scale} points={points} stroke="var(--text-2)" />
        ) : (
          <LineMark scale={scale} points={points} stroke="var(--text-2)" />
        )
      }
    </Chart>
  );
}

function ModLegend() {
  return (
    <div className="flex flex-wrap gap-2 pb-1">
      {MODS.map((m) => (
        <span key={m} className="flex items-center gap-1 text-[11px] text-[var(--text-3)]">
          <span className="size-2 rounded-full" style={{ background: MOD_COLOR[m] }} /> {m}
        </span>
      ))}
      <span className="flex items-center gap-1 text-[11px] text-[var(--text-3)]">
        <span className="size-2 rounded-full ring-1 ring-[var(--critical)]" /> retransmission
      </span>
    </div>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return <p className="panel p-8 text-center text-sm text-[var(--text-3)]">{children}</p>;
}

// ---------------------------------------------------------------------------------------------------- panels

function CarriersGrid({ analysis, palette, cursorMs }: { analysis: CaptureAnalysis; palette: BandPalette; cursorMs: number }) {
  const cells = activeCells(analysis.journey, cursorMs);
  const columns = [
    cells.find((c) => c.lane === "pcell"),
    ...cells.filter((c) => c.lane === "scell").sort((a, b) => a.index - b.index),
    cells.find((c) => c.lane === "pscell"),
  ].filter((c): c is JourneyCell => !!c);

  if (!columns.length) return <Empty>No cell was serving at the cursor.</Empty>;

  const detailOf = (c: JourneyCell) =>
    analysis.cellDetails.find((d) => d.cell.earfcn === c.cell.earfcn && d.cell.pci === c.cell.pci && d.cell.nr === c.cell.nr);
  // Every value is filtered to this column's own carrier index (audit A15).
  const at = (metric: PhyMetric, c: JourneyCell) =>
    sampleAt(seriesOf(analysis, metric), cursorMs, 1500, c.lane === "scell" ? c.index : 0);

  const rows: [string, (c: JourneyCell) => { text: string; staleMs?: number }][] = [
    ["EARFCN / ARFCN", (c) => ({ text: String(c.cell.earfcn) })],
    ["PCI", (c) => ({ text: c.cell.pci === 0xffff ? "pending" : String(c.cell.pci) })],
    ["Band", (c) => ({ text: c.band })],
    ["DL MHz", (c) => ({ text: fmtValue(c.dlMhz, "MHz") })],
    ["Bandwidth", (c) => ({ text: detailOf(c)?.bandwidthMhz != null ? `${detailOf(c)?.bandwidthMhz} MHz` : "—" })],
    ["Rx antennas", (c) => ({ text: rxAntennas(analysis, c) })],
    ["RSRP", (c) => sampleCell(at(c.cell.nr ? "nr_ss_rsrp" : "lte_rsrp_filtered", c), "dBm", cursorMs)],
    ["RSRQ", (c) => (c.cell.nr ? { text: "—" } : sampleCell(at("lte_rsrq_filtered", c), "dB", cursorMs))],
    ["CQI", (c) => (c.cell.nr ? { text: "—" } : sampleCell(at("lte_cqi_wideband_cw0", c), "", cursorMs))],
    ["RI", (c) => (c.cell.nr ? { text: "—" } : sampleCell(at("lte_ri", c), "", cursorMs))],
    ["DL MCS", (c) => sampleCell(at(c.cell.nr ? "nr_dl_mcs" : "lte_dl_mcs", c), "", cursorMs)],
    ["Layers", (c) => sampleCell(at(c.cell.nr ? "nr_dl_layers" : "lte_dl_layers", c), "", cursorMs)],
    ["BLER", (c) => sampleCell(at(c.cell.nr ? "nr_dl_bler" : "lte_dl_bler", c), "%", cursorMs)],
    ["Throughput", (c) => sampleCell(at(c.cell.nr ? "nr_dl_mac_throughput" : "lte_dl_phy_throughput", c), "Mbit/s", cursorMs)],
  ];

  return (
    <div className="panel overflow-x-auto p-3">
      <p className="mb-2 text-[11px] text-[var(--text-3)]">Values at the cursor, {fmtSince(cursorMs)}.</p>
      <table className="w-full min-w-[560px] text-[13px]">
        <thead>
          <tr className="border-b border-[var(--line)]">
            <th className="sticky left-0 bg-[var(--surface-1)] py-2 pr-3 text-left text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">
              Metric
            </th>
            {columns.map((c) => (
              <th key={`${c.lane}-${c.index}`} className="py-2 pr-3 text-left font-normal">
                <span className="chip num" style={{ borderColor: palette.colorOf(c.band) }}>
                  <span className="size-2 rounded-[2px]" style={{ background: palette.colorOf(c.band) }} />
                  {c.lane === "pcell" ? "PCell" : c.lane === "pscell" ? "NR PSCell" : `SCell ${c.index}`} · {c.band}
                </span>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map(([label, get]) => (
            <tr key={label} className="border-b border-[var(--line)] last:border-b-0">
              <td className="sticky left-0 bg-[var(--surface-1)] py-1.5 pr-3 text-[var(--text-3)]">{label}</td>
              {columns.map((c) => {
                const v = get(c);
                return (
                  <td
                    key={`${c.lane}-${c.index}-${label}`}
                    className={cn("num py-1.5 pr-3", v.staleMs != null && "text-[var(--text-3)]")}
                    title={v.staleMs != null ? `last value ${fmtValue(v.staleMs / 1000, "s")} s before the cursor` : undefined}
                  >
                    {v.text}
                  </td>
                );
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AntennaPanel({ analysis, cursorMs }: { analysis: CaptureAnalysis; cursorMs: number }) {
  const pcell = activeCells(analysis.journey, cursorMs).find((c) => c.lane === "pcell");
  const perRx = sampleAt(seriesOf(analysis, "lte_rsrp_per_rx"), cursorMs);
  const tx = analysis.phySummary.txAntennasMib;
  const rxEntries = Object.entries(analysis.phySummary.rxAntennasByEarfcn);
  const measured = analysis.phySummary.measuredAntennas ?? [];
  const bandOf = (earfcn: number, pci: number) =>
    analysis.journey.cells.find((c) => c.cell.earfcn === earfcn && c.cell.pci === pci)?.band;

  return (
    <div className="space-y-3">
      {measured.length > 0 ? (
        <section className="panel p-4">
          <h3 className="flex flex-wrap items-center gap-2 text-[13px] font-medium">
            Antennas, measured per serving cell
            <span className="chip num">0xB126 v163</span>
          </h3>
          <p className="mt-1 text-xs text-[var(--text-3)]">
            Read from the PDSCH demapper configuration, twenty subframes per record - not inferred from the MIB
            broadcast. The MIB's own antenna count is shown beside it as the cross-check.
          </p>
          <div className="-mx-4 mt-3 overflow-x-auto px-4">
          <table className="w-full min-w-[620px] text-[13px]">
            <thead>
              <tr className="border-b border-[var(--line)] text-[11px] uppercase tracking-[0.02em] text-[var(--text-3)]">
                <th className="py-1.5 text-left font-medium">Cell</th>
                <th className="py-1.5 text-left font-medium">Tx antenna ports</th>
                <th className="py-1.5 text-left font-medium">Rx antennas in use</th>
                <th className="py-1.5 text-left font-medium">MIMO rank</th>
                <th className="py-1.5 text-left font-medium">Broadcast (MIB)</th>
                <th className="py-1.5 text-left font-medium">Subframes</th>
              </tr>
            </thead>
            <tbody>
              {measured.map((m) => {
                const band = bandOf(m.earfcn, m.pci);
                const all = Object.entries(m.rankHistogram).sort((a, b) => Number(b[1]) - Number(a[1]));
                const total = all.reduce((n, [, v]) => n + Number(v), 0) || 1;
                // A rank seen in a handful of subframes rounds to 0%: it is noise in a summary line.
                const ranks = all.filter(([, v]) => Number(v) / total >= 0.005).slice(0, 3);
                return (
                  <tr key={`${m.earfcn}-${m.pci}`} className="border-b border-[var(--line)] last:border-b-0">
                    <td className="num py-1.5">{band ? `${band} · PCI ${m.pci}` : `EARFCN ${m.earfcn} · PCI ${m.pci}`}</td>
                    <td className="num py-1.5 text-[15px]">{m.txPorts}</td>
                    <td className="num py-1.5 text-[15px]">
                      {m.rxAntennas}
                      <span className="chip ml-1.5" title="88-93% agreement with the receive antennas 0xB193 measured.">medium</span>
                    </td>
                    <td className="num py-1.5 text-[var(--text-3)]">
                      {ranks.map(([rank, n]) => `${rank}: ${((Number(n) / total) * 100).toFixed(0)}%`).join(", ")}
                    </td>
                    <td className="num py-1.5">
                      {m.mibTxAntennas == null
                        ? <span className="text-[var(--text-3)]">no MIB captured</span>
                        : m.mibTxAntennas === m.txPorts
                        ? <span className="text-[var(--good)]">{m.mibTxAntennas} ✓</span>
                        : <span className="text-[var(--warning)]">{m.mibTxAntennas}</span>}
                    </td>
                    <td className="num py-1.5 text-[var(--text-3)]">{m.subframes.toLocaleString("en-US")}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          </div>
          <p className="mt-2 text-[11px] text-[var(--text-3)]">
            The transmit-antenna field follows the serving cell rather than the scheduling, which is what makes it an
            antenna-port count and not the transmission mode. Where a cell's MIB was captured the two agree.
          </p>
        </section>
      ) : (
        <section className="panel p-4">
          <h3 className="text-[13px] font-medium">What the cell transmits with</h3>
          <p className="num mt-1 text-[20px] font-medium leading-7">
            {tx.length ? tx.map((n) => `${n}`).join(" / ") : "—"}
            <span className="ml-2 text-[13px] font-normal text-[var(--text-3)]">
              {tx.length ? "transmit antennas, from the MIB broadcast" : "not seen in this capture"}
            </span>
          </p>
          <p className="mt-1 text-xs text-[var(--text-3)]">
            No PDSCH demapper records (0xB126) in this capture, so this is the broadcast's own figure rather than a
            measurement.
          </p>
        </section>
      )}
      <section className="panel p-4">
        <h3 className="text-[13px] font-medium">What the phone measured with</h3>
        <dl className="mt-2 space-y-1">
          {rxEntries.length === 0 && <p className="text-sm text-[var(--text-3)]">No receive-antenna records in this capture.</p>}
          {rxEntries.map(([earfcn, counts]) => (
            <div key={earfcn} className="grid grid-cols-[132px_minmax(0,1fr)] gap-3 border-b border-[var(--line)] pb-1 last:border-b-0">
              <dt className="num text-[var(--text-3)]">EARFCN {earfcn}</dt>
              <dd className="num">
                {Object.entries(counts).map(([rx, n]) => `${rx} Rx (${n.toLocaleString("en-US")} records)`).join(", ")}
              </dd>
            </div>
          ))}
        </dl>
      </section>
      <section className="panel p-4">
        <h3 className="text-[13px] font-medium">RSRP per antenna at the cursor</h3>
        <div className="mt-3 space-y-1.5">
          {(perRx?.perIndex ?? [null]).map((v, i) => (
            <div key={i} className="grid grid-cols-[40px_minmax(0,1fr)_84px] items-center gap-2">
              <span className="num text-[11px] text-[var(--text-3)]">Rx{i}</span>
              <div className="h-2.5 rounded-[2px] bg-[var(--surface-2)]">
                <div
                  className="h-full rounded-[2px]"
                  style={{
                    width: v == null ? "0%" : `${Math.max(2, Math.min(100, ((v + 130) / 60) * 100))}%`,
                    background: SEQUENTIAL[i % SEQUENTIAL.length],
                  }}
                />
              </div>
              <span className="num text-right text-[11px]">{fmtMetric(v, "dBm")}</span>
            </div>
          ))}
        </div>
        <p className="mt-2 text-[11px] text-[var(--text-3)]">
          {pcell ? `Serving on ${pcell.band}, PCI ${pcell.cell.pci}.` : "No serving cell at the cursor."}
          {perRx && <> Signal is {rsrpQuality(perRx.value).label}.</>}
        </p>
      </section>
    </div>
  );
}

function RachPanel({ analysis, onCursor }: { analysis: CaptureAnalysis; onCursor: (ms: number) => void }) {
  const rach = analysis.phySummary.rach;
  if (!rach.length) return <Empty>No random-access responses were logged.</Empty>;
  return (
    <section className="panel overflow-hidden">
      <h3 className="border-b border-[var(--line)] px-3 py-2 text-[13px] font-medium">
        Random access <span className="num text-[var(--text-3)]">{rach.length}</span>
      </h3>
      <table className="w-full text-[13px]">
        <thead>
          <tr className="border-b border-[var(--line)] text-[11px] uppercase tracking-[0.02em] text-[var(--text-3)]">
            <th className="px-3 py-1.5 text-left font-medium">Time</th>
            <th className="py-1.5 text-left font-medium">UL EARFCN</th>
            <th className="py-1.5 text-left font-medium">Timing advance</th>
            <th className="py-1.5 text-left font-medium">Distance</th>
            <th className="py-1.5 text-left font-medium">Preamble target</th>
          </tr>
        </thead>
        <tbody>
          {rach.map((r) => (
            <tr key={r.tMs} className="border-b border-[var(--line)] last:border-b-0 hover:bg-[var(--surface-2)]">
              <td className="px-3 py-1.5">
                <button className="num underline-offset-2 hover:underline" onClick={() => onCursor(r.tMs)}>
                  {fmtSince(r.tMs)}
                </button>
              </td>
              <td className="num py-1.5">{r.ulEarfcn ?? "—"}</td>
              <td className="num py-1.5">{r.ta}</td>
              <td className="num py-1.5">{r.distanceM == null ? "—" : `≈ ${fmtValue(r.distanceM)} m`}</td>
              <td className="num py-1.5">{fmtMetric(r.preambleTargetDbm, "dBm")}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="px-3 py-2 text-[11px] text-[var(--text-3)]">
        Distance is the timing advance times 78.12 m: how far the phone was told it is from the cell, not where it was.
      </p>
    </section>
  );
}

const AVAILABILITY_GROUPS: { status: AvailabilityStatus; heading: string; icon: typeof Lock }[] = [
  // Entries a new decoder has since answered stay on this page, with what was validated and what was rejected.
  { status: "available", heading: "Answered, with what was and was not validated", icon: CircleCheck },
  { status: "encryptedByModem", heading: "Encrypted by the modem", icon: Lock },
  { status: "notFoundInPlainLogs", heading: "Not in the plain records", icon: SearchX },
  { status: "notDecodedYet", heading: "Not decoded yet", icon: Clock },
  { status: "notOnIPhone", heading: "Not possible on iPhone", icon: Ban },
];

function NotAvailablePanel({ analysis }: { analysis: CaptureAnalysis }) {
  const byCode = Object.entries(analysis.encrypted.byCode ?? {})
    .sort((a, b) => b[1] - a[1])
    .slice(0, 12);
  return (
    <div className="space-y-3">
      <section className="panel p-4">
        <h3 className="flex items-center gap-2 text-[13px] font-medium">
          <Lock className="size-4 text-[var(--text-3)]" /> Encrypted by the modem
        </h3>
        <p className="num mt-1 text-[20px] font-medium leading-7">
          {analysis.encrypted.records.toLocaleString("en-US")}
          <span className="ml-2 text-[13px] font-normal text-[var(--text-3)]">
            records in {analysis.encrypted.codes} log codes, counted but never decoded
          </span>
        </p>
        {byCode.length > 0 && (
          <p className="mt-2 flex flex-wrap gap-1">
            {byCode.map(([code, n]) => (
              <span key={code} className="chip num">{code} · {n.toLocaleString("en-US")}</span>
            ))}
          </p>
        )}
      </section>

      {AVAILABILITY_GROUPS.map(({ status, heading, icon: Icon }) => {
        const items = analysis.availability.filter((a) => a.status === status);
        if (!items.length) return null;
        return (
          <section key={status} className="panel p-4">
            <h3 className="flex items-center gap-2 text-[13px] font-medium">
              <Icon className="size-4 text-[var(--text-3)]" /> {heading}
            </h3>
            <div className="mt-2 space-y-2">
              {items.map((a) => (
                <div key={a.id} className="border-b border-[var(--line)] pb-2 last:border-b-0 last:pb-0">
                  <p className="text-[13px] font-medium">{a.title}</p>
                  <p className="mt-0.5 text-xs text-[var(--text-3)]">{a.reason}</p>
                  {a.codes?.length ? (
                    <p className="mt-1 flex flex-wrap gap-1">{a.codes.map((c) => <span key={c} className="chip num">{c}</span>)}</p>
                  ) : null}
                </div>
              ))}
            </div>
          </section>
        );
      })}

      <section className="panel p-4">
        <h3 className="text-[13px] font-medium">Decoder health</h3>
        <p className="mt-0.5 text-xs text-[var(--text-3)]">
          Each decoder checked against a physical or 3GPP identity that has to hold.
        </p>
        <div className="mt-2 space-y-1.5">
          {analysis.phyChecks.map((c) => (
            <div key={c.id} className="grid grid-cols-[18px_minmax(0,1fr)] gap-2 border-b border-[var(--line)] pb-1.5 last:border-b-0">
              {c.passed ? <CircleCheck className="size-4 text-[var(--good)]" /> : <XCircle className="size-4 text-[var(--critical)]" />}
              <div className="min-w-0">
                <p className="num text-xs">{c.code}</p>
                <p className="num text-xs text-[var(--text-2)]">{c.measured}</p>
                <p className="text-xs text-[var(--text-3)]">{c.expectation}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section className="panel p-4">
        <h3 className="text-[13px] font-medium">Skipped records</h3>
        {Object.keys(analysis.versionMisses).length ? (
          <ul className="mt-2 space-y-1">
            {Object.entries(analysis.versionMisses).map(([k, v]) => (
              <li key={k} className="num text-xs text-[var(--text-2)]">{k} · {v.toLocaleString("en-US")} records</li>
            ))}
          </ul>
        ) : (
          <p className="mt-1 text-sm text-[var(--text-3)]">No skipped records: every version seen was one the decoder has validated.</p>
        )}
      </section>
    </div>
  );
}

// ----------------------------------------------------------------------------------------------------- utils

/** Every series the engine filed under a section that is worth a chart, so the rail's count and the charts agree. */
function sectionSeries(analysis: CaptureAnalysis, section: PhySeries["section"]): (PhySeries & { perIndexSeries?: boolean })[] {
  return analysis.phy
    .filter((s) => s.section === section && !SHOWN_ELSEWHERE.has(s.metric))
    .map((s) => (s.samples.some((x) => x.perIndex?.length) ? { ...s, perIndexSeries: true } : s));
}

/**
 * Per-antenna series carry their values in `perIndex`, which the value-based decimator cannot see, so they are
 * thinned by a stride instead. Without this a real capture puts tens of thousands of points in one path.
 */
function thin<T>(items: T[], max = 1500): T[] {
  if (items.length <= max) return items;
  const stride = Math.ceil(items.length / max);
  return items.filter((_, i) => i % stride === 0);
}

function windowed(series: PhySeries | undefined, [start, end]: [number, number]): PhySample[] {
  if (!series) return [];
  return series.samples.filter((s) => s.tMs >= start && s.tMs <= end);
}

function valueText(sample: PhySample | undefined, unit: string): string {
  if (!sample || sample.value == null) return "—";
  return fmtMetric(sample.value, unit);
}

/** A value older than 1.5 s is shown dimmed, with how stale it is in the tooltip. */
function sampleCell(sample: PhySample | undefined, unit: string, cursorMs: number): { text: string; staleMs?: number } {
  if (!sample || sample.value == null) return { text: "—" };
  const age = cursorMs - sample.tMs;
  const text = fmtMetric(sample.value, unit);
  return age > 1500 ? { text, staleMs: age } : { text };
}

function rxAntennas(analysis: CaptureAnalysis, c: JourneyCell): string {
  const counts = analysis.phySummary.rxAntennasByEarfcn[String(c.cell.earfcn)];
  if (!counts) return "—";
  const best = Object.entries(counts).sort((a, b) => b[1] - a[1])[0];
  return best ? best[0] : "—";
}

/** A stable colour per PCI / per transmit chain, off the sequential ramp: these are identities, not magnitudes. */
function rampColor(key: string): string {
  let hash = 0;
  for (let i = 0; i < key.length; i++) hash = (hash * 31 + key.charCodeAt(i)) | 0;
  return SEQUENTIAL[Math.abs(hash) % SEQUENTIAL.length] as string;
}

const pciColor = (pci: number): string => rampColor(`pci-${pci}`);
const chainColor = (tag: string): string => rampColor(`chain-${tag.replace(/ at limit$/, "")}`);

function chainLegend(analysis: CaptureAnalysis): { chain: string; color: string }[] {
  return (analysis.phySummary.uplinkFrontEnd?.chains ?? [])
    .filter((c) => c.liveSamples > 0)
    .map((c) => ({ chain: c.chain, color: chainColor(`chain ${c.chain}`) }));
}

const signedDb = (v: number): string => `${v > 0 ? "+" : ""}${v.toFixed(1)} dB`;

/** Bytes as a report reads them: 655,956 bytes is "656 kB", 2,235,835 is "2.24 MB". */
function fmtBytes(bytes: number): string {
  if (bytes >= 1e6) return `${(bytes / 1e6).toFixed(2)} MB`;
  if (bytes >= 1e3) return `${Math.round(bytes / 1e3).toLocaleString("en-US")} kB`;
  return `${bytes.toLocaleString("en-US")} B`;
}

function modulationMix(series: PhySeries | undefined, view: [number, number]): { t: number; parts: Record<string, number> }[] {
  if (!series) return [];
  const buckets = new Map<number, Record<string, number>>();
  for (const s of windowed(series, view)) {
    if (!s.tag || !(MODS as readonly string[]).includes(s.tag)) continue;
    const t = Math.floor(s.tMs / 1000) * 1000;
    const row = buckets.get(t) ?? {};
    row[s.tag] = (row[s.tag] ?? 0) + 1;
    buckets.set(t, row);
  }
  return [...buckets.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([t, row]) => {
      const total = MODS.reduce((n, m) => n + (row[m] ?? 0), 0) || 1;
      const parts: Record<string, number> = {};
      for (const m of MODS) parts[m] = ((row[m] ?? 0) / total) * 100;
      return { t: t + 500, parts };
    });
}

function carrierKeys(series: PhySeries | undefined, palette: BandPalette): { key: string; label: string; color: string }[] {
  if (!series) return [];
  const keys = [...new Set(series.samples.map((s) => String(s.carrier ?? 0)))].sort();
  return keys.map((key) => {
    const sample = series.samples.find((s) => String(s.carrier ?? 0) === key);
    const band = sample?.cell ? palette.bandOf(sample.cell) : undefined;
    const index = Number(key);
    return {
      key,
      label: band ? `${index === 0 ? "PCell" : `SCell ${index}`} ${band}` : index === 0 ? "PCell" : `SCell ${index}`,
      color: band ? palette.colorOf(band) : "var(--text-2)",
    };
  });
}

function stackByCarrier(
  series: PhySeries | undefined,
  view: [number, number],
): { t: number; parts: Record<string, number> }[] {
  if (!series) return [];
  const buckets = new Map<number, Record<string, number>>();
  for (const s of windowed(series, view)) {
    if (s.value == null) continue;
    const t = Math.round(s.tMs / 1000) * 1000;
    const row = buckets.get(t) ?? {};
    const key = String(s.carrier ?? 0);
    row[key] = (row[key] ?? 0) + s.value;
    buckets.set(t, row);
  }
  return [...buckets.entries()].sort((a, b) => a[0] - b[0]).map(([t, parts]) => ({ t, parts }));
}

function countOf(analysis: CaptureAnalysis, section: RadioSection, cursorMs: number): number {
  switch (section) {
    case "Carriers": return activeCells(analysis.journey, cursorMs).length;
    case "Antennas": return Object.keys(analysis.phySummary.rxAntennasByEarfcn).length;
    case "RACH": return analysis.phySummary.rach.length;
    case "Not available": return analysis.availability.filter((a) => a.status !== "available").length;
    case "Neighbours": return (analysis.phySummary.intraFreqNeighbours ?? []).length;
    case "Signal": return sectionSeries(analysis, "signal").length;
    case "Downlink": return sectionSeries(analysis, "downlink").length;
    case "Uplink": return sectionSeries(analysis, "uplink").length;
    case "CSI": return sectionSeries(analysis, "csi").length;
    case "NR": return sectionSeries(analysis, "nr").length;
    default: return 0;
  }
}
