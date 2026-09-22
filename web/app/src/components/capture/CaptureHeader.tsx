// 56 px, not sticky: what this file is, when it was recorded, what the modem kept, and whether the logging
// profile still works. Every string comes from the analysis (audit E5: the UI never re-derives a number).
import { CircleCheck, OctagonX, RadioTower, Sparkles, TriangleAlert } from "lucide-react";
import { ExportReport } from "@/components/capture/ExportReport";
import { fmtDuration, pressWindow, profileLine, recordedAt, signedSeconds } from "@/lib/analysis/format";
import type { CaptureAnalysis, Severity } from "@engine/types";

export function CaptureHeader({ analysis }: { analysis: CaptureAnalysis }) {
  const profile = profileLine(analysis);
  const isSample = analysis.fileName.includes("_SAMPLE");
  const isDev = analysis.fileName.startsWith("dev:");

  return (
    // Flex, not grid. The mast icon is `hidden` below 640 px, which takes it out of the grid's item list
    // entirely and shifts every remaining child one column left — the export button landed in the 1fr track and
    // was squeezed to an 18 px box with its icon collapsed to nothing. A flex row does not care how many
    // children there are: the middle grows, the ends keep their size.
    <header className="flex min-h-14 items-center gap-3 border-b border-[var(--line)] py-2">
      <RadioTower className="hidden size-5 shrink-0 text-[var(--action)] sm:block" />
      <div className="min-w-0 flex-1">
        <h1 className="num truncate text-[13px] font-medium" title={analysis.fileName}>
          {middleTruncate(analysis.fileName)}
        </h1>
        <div className="mt-1 flex min-w-0 gap-1.5 overflow-x-auto pb-0.5">
          {isSample && (
            <span className="chip shrink-0 border-[var(--action)]/45 text-[var(--text-2)]">
              <Sparkles className="size-3" /> Sample · synthetic data
            </span>
          )}
          {isDev && <span className="chip shrink-0 border-[var(--warning)]/50">Dev fixture · not committed</span>}
          <span className="chip num shrink-0">{recordedAt(analysis)}</span>
          <span className="chip num shrink-0">{traceWindowChip(analysis)}</span>
          <span className="chip shrink-0">
            <StatusIcon severity={profile.severity} /> {profile.text}
          </span>
        </div>
      </div>
      <ExportReport analysis={analysis} className="shrink-0 self-start" label="Export" />
    </header>
  );
}

export function StatusIcon({ severity }: { severity: Severity }) {
  if (severity === "failure") return <OctagonX className="size-3 text-[var(--critical)]" />;
  if (severity === "warning") return <TriangleAlert className="size-3 text-[var(--warning)]" />;
  return <CircleCheck className="size-3 text-[var(--good)]" />;
}

function traceWindowChip(analysis: CaptureAnalysis): string {
  const t = analysis.traceWindow;
  if (!t || analysis.durationMs <= 0) return "No modem trace";
  const length = fmtDuration(analysis.durationMs);
  const press = pressWindow(analysis);
  if (!press) return `${length} trace`;
  // The press time is only good to about a second: pressWindow rounds it once, for every view (format.ts).
  return `${length} trace · ${signedSeconds(press.from, true)}–${signedSeconds(press.to, true)} around the press`;
}

function middleTruncate(name: string): string {
  if (name.length <= 56) return name;
  return `${name.slice(0, 26)}…${name.slice(-26)}`;
}
