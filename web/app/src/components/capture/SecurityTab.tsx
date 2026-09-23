// Security: the local fake-base-station / IMSI-catcher check over the decoded RRC/NAS call flow. It is calm by
// design — most captures are clean and the banner says so — and every finding names the decoded evidence it read.
// Nothing here re-derives a verdict; it renders the SecurityReport the engine produced (or the app computed with
// the same pure engine function). No network, in keeping with the app's on-device promise.
import {
  ChevronRight, Info, Radio, ShieldAlert, ShieldCheck, ShieldQuestion, TriangleAlert,
} from "lucide-react";
import { bandChip, fmtSince } from "@/lib/analysis/format";
import { securityOf } from "@/lib/analysis/select";
import { useBandPalette } from "@/lib/analysis/palette";
import type { CaptureAnalysis, SecurityCellVerdict, SecurityFinding, SecurityVerdict } from "@engine/types";

const TONE: Record<SecurityVerdict, { color: string; label: string }> = {
  trusted: { color: "var(--good)", label: "Clean" },
  warning: { color: "var(--warning)", label: "Worth a look" },
  suspicious: { color: "var(--critical)", label: "Suspicious" },
};

export function SecurityTab({
  analysis, onJump,
}: {
  analysis: CaptureAnalysis;
  onJump: (tMs: number, event?: number) => void;
}) {
  const report = securityOf(analysis);

  return (
    <div className="grid min-w-0 grid-cols-1 gap-4 lg:grid-cols-12">
      <div className="min-w-0 space-y-4 lg:col-span-8">
        <Banner verdict={report.verdict} headline={report.headline} />

        {report.cells.length === 0 && report.findings.length === 0 ? (
          <section className="panel p-4">
            <h2 className="flex items-center gap-2 text-[13px] font-medium">
              <ShieldCheck className="size-4" style={{ color: "var(--good)" }} /> Nothing flagged
            </h2>
            <p className="mt-1.5 text-[13px] leading-5 text-[var(--text-2)]">
              Every Layer-3 check ran and found no fake-base-station signature. The network set up ciphering and
              integrity, asked for no permanent identity in the clear, and never forced a downgrade or a stranding
              reject.
            </p>
          </section>
        ) : (
          <>
            {report.cells.map((c) => <CellCard key={`${c.cell.earfcn}-${c.cell.pci}`} verdict={c} analysis={analysis} onJump={onJump} />)}
            {report.findings.length > 0 && (
              <section className="panel min-w-0 overflow-hidden">
                <div className="flex h-11 items-center border-b border-[var(--line)] px-3">
                  <h2 className="text-[13px] font-medium">Capture-wide</h2>
                </div>
                {report.findings.map((f) => <FindingRow key={f.id} finding={f} onJump={onJump} />)}
              </section>
            )}
          </>
        )}
      </div>

      <aside className="min-w-0 space-y-4 lg:col-span-4">
        <WhatThisCatches />
        <ChecksRun report={report} />
      </aside>
    </div>
  );
}

function Banner({ verdict, headline }: { verdict: SecurityVerdict; headline: string }) {
  const tone = TONE[verdict];
  const Icon = verdict === "trusted" ? ShieldCheck : verdict === "warning" ? ShieldQuestion : ShieldAlert;
  return (
    <section
      className="panel flex items-start gap-3 p-4"
      style={{
        borderColor: `color-mix(in oklab, ${tone.color} 45%, var(--line))`,
        background: `color-mix(in oklab, ${tone.color} 8%, var(--surface-1))`,
      }}
      aria-label={`Security verdict: ${tone.label}`}
    >
      <Icon className="mt-0.5 size-5 shrink-0" style={{ color: tone.color }} />
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <h1 className="text-[15px] font-semibold">Fake base station check</h1>
          <span
            className="rounded-full px-2 py-0.5 text-[11px] font-medium"
            style={{ background: `color-mix(in oklab, ${tone.color} 18%, transparent)`, color: tone.color }}
          >
            {tone.label}
          </span>
        </div>
        <p className="mt-1 text-[13px] leading-5 text-[var(--text-2)]">{headline}</p>
      </div>
    </section>
  );
}

function CellCard({
  verdict, analysis, onJump,
}: {
  verdict: SecurityCellVerdict;
  analysis: CaptureAnalysis;
  onJump: (tMs: number, event?: number) => void;
}) {
  const palette = useBandPalette(analysis);
  const tone = TONE[verdict.verdict];
  const band = verdict.band ?? bandChip(verdict.cell, analysis);
  return (
    <section className="panel min-w-0 overflow-hidden" style={{ borderColor: `color-mix(in oklab, ${tone.color} 35%, var(--line))` }}>
      <div className="flex h-11 items-center gap-2 border-b border-[var(--line)] px-3">
        <Radio className="size-4 text-[var(--text-3)]" />
        <span className="chip num" style={{ borderColor: palette.colorOf(band) }}>
          <span className="size-2 rounded-[2px]" style={{ background: palette.colorOf(band) }} />
          {band}
        </span>
        <span className="num text-[13px] text-[var(--text-2)]">
          {verdict.cell.nr ? "NR-ARFCN" : "EARFCN"} {verdict.cell.earfcn} · PCI {verdict.cell.pci}
        </span>
        <span className="ml-auto text-[11px] font-medium" style={{ color: tone.color }}>{tone.label}</span>
      </div>
      {verdict.findings.map((f) => <FindingRow key={f.id} finding={f} onJump={onJump} />)}
    </section>
  );
}

function FindingRow({ finding, onJump }: { finding: SecurityFinding; onJump: (tMs: number, event?: number) => void }) {
  const color = finding.severity === "suspicious" ? "var(--critical)" : finding.severity === "warning" ? "var(--warning)" : "var(--text-2)";
  const Icon = finding.severity === "info" ? Info : TriangleAlert;
  const clickable = finding.tMs != null;
  const body = (
    <>
      <Icon className="mt-0.5 size-[18px] shrink-0" style={{ color }} />
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-[13px] font-medium">{finding.title}</span>
          {finding.tMs != null && <span className="num text-[11px] text-[var(--text-3)]">{fmtSince(finding.tMs)}</span>}
          {clickable && <ChevronRight className="size-3.5 text-[var(--text-3)] opacity-0 group-hover:opacity-100" />}
        </div>
        <p className="mt-0.5 text-[13px] leading-5 text-[var(--text-2)]">{finding.explanation}</p>
        <ul className="mt-1.5 space-y-0.5">
          {finding.evidence.map((e, i) => (
            <li key={i} className="num text-[11px] leading-4 text-[var(--text-3)]">
              <span className="mr-1 text-[var(--text-3)]">evidence:</span>{e}
            </li>
          ))}
        </ul>
      </div>
    </>
  );
  return clickable ? (
    <button
      className="group grid w-full grid-cols-[18px_minmax(0,1fr)] items-start gap-2 border-b border-[var(--line)] px-3 py-2.5 text-left last:border-b-0 hover:bg-[var(--surface-2)]"
      style={{ boxShadow: `inset 2px 0 0 0 ${color}` }}
      onClick={() => onJump(finding.tMs ?? 0, finding.event)}
      title={`Move the cursor to ${fmtSince(finding.tMs ?? 0)}`}
    >
      {body}
    </button>
  ) : (
    <div className="grid grid-cols-[18px_minmax(0,1fr)] items-start gap-2 border-b border-[var(--line)] px-3 py-2.5 last:border-b-0" style={{ boxShadow: `inset 2px 0 0 0 ${color}` }}>
      {body}
    </div>
  );
}

function WhatThisCatches() {
  return (
    <section className="panel p-4">
      <h2 className="flex items-center gap-2 text-[13px] font-medium">
        <Info className="size-4 text-[var(--text-3)]" /> What this can and can't catch
      </h2>
      <p className="mt-1.5 text-[13px] leading-5 text-[var(--text-2)]">
        This reads the decoded RRC/NAS signalling for the Layer-3 tells of a fake base station: null or absent
        ciphering, the IMSI asked for in the clear, a forced 2G/3G downgrade, a registration accepted with no
        security, a stranding reject cause, an implausibly strong cell, and a cell reached with no mobility
        context.
      </p>
      <p className="mt-2 text-[13px] leading-5 text-[var(--text-2)]">
        It is <span className="font-medium text-[var(--text)]">not a guarantee</span>. A sophisticated catcher that
        mimics a real cell — running real ciphering and a valid-looking security setup — can pass every check here.
        A clean result means no Layer-3 anomaly was found, not that no catcher was present. Everything runs on this
        device; nothing about your capture leaves it.
      </p>
    </section>
  );
}

function ChecksRun({ report }: { report: ReturnType<typeof securityOf> }) {
  return (
    <section className="panel p-4">
      <h2 className="text-[13px] font-medium">Checks that ran</h2>
      <div className="mt-2 flex flex-wrap gap-1.5">
        {report.checksRun.map((c) => (
          <span key={c} className="num rounded-md border border-[var(--line)] bg-[var(--surface-2)] px-1.5 py-0.5 text-[11px] text-[var(--text-3)]">
            {c}
          </span>
        ))}
      </div>
      {report.gaps.length > 0 && (
        <>
          <h3 className="mt-3 text-[11px] font-medium uppercase tracking-[0.02em] text-[var(--text-3)]">Not yet supported</h3>
          <ul className="mt-1.5 space-y-1.5">
            {report.gaps.map((g) => (
              <li key={g.check} className="text-[12px] leading-4 text-[var(--text-3)]">
                <span className="num text-[var(--text-2)]">{g.check}</span> — {g.reason}
              </li>
            ))}
          </ul>
        </>
      )}
      <p className="mt-3 border-t border-[var(--line)] pt-2 text-[11px] text-[var(--text-3)]">
        Ruleset {report.ruleset}
      </p>
    </section>
  );
}
