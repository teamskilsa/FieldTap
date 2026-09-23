// One band palette per capture (audit E2). The same band keeps its appearance in every view — timeline segments,
// chips, stacked throughput, the minimap, the carriers grid.
//
// Band colours mean cells and nothing else. Ordinal data (modulation order, Rx index) uses the sequential blue
// ramp instead, which is why that lives here too (audit A23).
//
// ------------------------------------------------------------------------------------------ the encoding rule
//
// We have exactly three colour-blind-safe hues (--band-1 blue, --band-2 orange, --band-3 green) that are also
// distinguishable from the NR pink and from each other in both themes. A real capture routinely carries more LTE
// bands than that: the reference capture has six (B12, B2, B29, B30, B66, B14). Giving bands four and up the same
// grey made two lanes indistinguishable, which is worse than no encoding at all, so:
//
//   1. Rank the LTE bands by *time on air* — the total length of their segments across every lane — because the
//      band that carried the most of the capture is the one the eye should be able to track without reading.
//      Ties (and bands with no measurable length) fall back to the order they first appear.
//   2. The top three take the three hues, drawn solid.
//   3. Every remaining band takes the neutral --band-other and a distinct *pattern*: hatch, dots, cross-hatch,
//      cycling in rank order. Patterns survive greyscale, printing and every kind of colour blindness.
//   4. A patterned band always draws its label on its segments (`alwaysLabel`), even when the segment is only
//      wide enough for the band name. Pattern plus word means two neutral lanes are never ambiguous — if a
//      capture ever carries a seventh LTE band the patterns repeat, and the label is what still separates them.
//   5. Every NR band takes --band-nr, solid. NR is one leg, not a set of peers.
//
// The legend states the rule, and the `bands` list is in the same rank order it uses.
import { useMemo } from "react";
import type { CaptureAnalysis, Cell, JourneyCell } from "@engine/types";

/** How a band's segments are filled. 'solid' is a hue; the rest are the neutral colour plus a texture. */
export type BandPattern = "solid" | "hatch" | "dots" | "crossHatch";

export const PATTERN_LABEL: Record<BandPattern, string> = {
  solid: "solid",
  hatch: "hatched",
  dots: "dotted",
  crossHatch: "cross-hatched",
};

export interface BandEncoding {
  band: string;
  color: string;
  pattern: BandPattern;
  nr: boolean;
  /** Total time this band was on air, in ms — the number that decided its rank. */
  onAirMs: number;
}

export interface BandPalette {
  /** A CSS colour for a band name ('B66', 'n77'). */
  colorOf: (band: string) => string;
  /** How this band's segments are textured. */
  patternOf: (band: string) => BandPattern;
  /** True when the band fell past the three validated hues and is drawn with a neutral pattern instead. */
  patterned: (band: string) => boolean;
  /** True when a segment of this band must show its label however narrow it is (see rule 4). */
  alwaysLabel: (band: string) => boolean;
  /** The flat fill for a segment: the band tinted into the panel surface, so label text stays readable. */
  fillOf: (band: string) => string;
  /** The complete CSS `background` for a segment: the fill, plus the pattern when the band has one. */
  backgroundOf: (band: string) => string;
  /** The band of a cell as the journey names it, or a readable fallback. */
  bandOf: (cell: Cell | undefined) => string;
  /** Every band, ranked as the rule above ranks them, for the legend. */
  bands: BandEncoding[];
}

const LTE_HUES = ["var(--band-1)", "var(--band-2)", "var(--band-3)"];
const NEUTRAL_PATTERNS: BandPattern[] = ["hatch", "dots", "crossHatch"];
const OTHER = "var(--band-other)";
const NR = "var(--band-nr)";

/** The sequential ramp, darkest first. Ordinal series only. */
export const SEQUENTIAL = ["var(--seq-100)", "var(--seq-200)", "var(--seq-300)", "var(--seq-400)"];

/** The texture layer for a pattern, drawn over the flat fill. Empty for 'solid'. */
export function patternLayer(pattern: BandPattern, color: string): string {
  switch (pattern) {
    case "hatch":
      return `repeating-linear-gradient(45deg, ${color} 0 2px, transparent 2px 6px)`;
    case "crossHatch":
      return `repeating-linear-gradient(45deg, ${color} 0 1.5px, transparent 1.5px 6px), ` +
        `repeating-linear-gradient(-45deg, ${color} 0 1.5px, transparent 1.5px 6px)`;
    case "dots":
      return `radial-gradient(${color} 1.1px, transparent 1.3px) 0 0 / 5px 5px`;
    default:
      return "";
  }
}

export function buildBandPalette(analysis: CaptureAnalysis): BandPalette {
  const cells: JourneyCell[] = [...analysis.journey.cells].sort((a, b) => a.startMs - b.startMs);

  // Time on air per LTE band, and the order each band was first seen in (the tie-break).
  const onAir = new Map<string, number>();
  const firstSeen = new Map<string, number>();
  const nrBands = new Set<string>();
  for (const c of cells) {
    if (c.cell.nr || c.lane === "pscell") {
      nrBands.add(c.band);
      continue;
    }
    if (!firstSeen.has(c.band)) firstSeen.set(c.band, firstSeen.size);
    onAir.set(c.band, (onAir.get(c.band) ?? 0) + Math.max(0, c.endMs - c.startMs));
  }

  const ranked = [...onAir.keys()].sort(
    (a, b) => (onAir.get(b) ?? 0) - (onAir.get(a) ?? 0) || (firstSeen.get(a) ?? 0) - (firstSeen.get(b) ?? 0),
  );
  const rankOf = new Map(ranked.map((band, i) => [band, i]));

  const isNr = (band: string) => nrBands.has(band) || band.startsWith("n");
  const colorOf = (band: string): string => {
    if (isNr(band)) return NR;
    const rank = rankOf.get(band);
    return rank != null && rank < LTE_HUES.length ? (LTE_HUES[rank] as string) : OTHER;
  };
  const patternOf = (band: string): BandPattern => {
    if (isNr(band)) return "solid";
    const rank = rankOf.get(band);
    if (rank == null || rank < LTE_HUES.length) return "solid";
    return NEUTRAL_PATTERNS[(rank - LTE_HUES.length) % NEUTRAL_PATTERNS.length] as BandPattern;
  };
  const patterned = (band: string) => patternOf(band) !== "solid";
  // 30% of the band over the panel surface in dark, 16% over white in light: label text reads at 7.6:1 or better.
  const fillOf = (band: string) => `color-mix(in oklab, ${colorOf(band)} var(--segment-tint), var(--surface-1))`;
  const backgroundOf = (band: string) => {
    const layer = patternLayer(patternOf(band), colorOf(band));
    return layer ? `${layer}, ${fillOf(band)}` : fillOf(band);
  };

  return {
    colorOf,
    patternOf,
    patterned,
    alwaysLabel: patterned,
    fillOf,
    backgroundOf,
    bandOf: (cell) => {
      if (!cell) return "—";
      const known = analysis.journey.cells.find(
        (c) => c.cell.earfcn === cell.earfcn && c.cell.pci === cell.pci && c.cell.nr === cell.nr,
      );
      if (known) return known.band;
      if (cell.nr) return "NR";
      const detail = analysis.cellDetails.find(
        (d) => d.cell.earfcn === cell.earfcn && d.cell.pci === cell.pci && d.cell.nr === cell.nr,
      );
      return detail ? `B${detail.band}` : `EARFCN ${cell.earfcn}`;
    },
    bands: [
      ...ranked.map((band) => ({
        band,
        color: colorOf(band),
        pattern: patternOf(band),
        nr: false,
        onAirMs: onAir.get(band) ?? 0,
      })),
      ...[...nrBands].map((band) => ({
        band,
        color: NR,
        pattern: "solid" as const,
        nr: true,
        onAirMs: cells
          .filter((c) => c.band === band)
          .reduce((n, c) => n + Math.max(0, c.endMs - c.startMs), 0),
      })),
    ],
  };
}

export function useBandPalette(analysis: CaptureAnalysis): BandPalette {
  return useMemo(() => buildBandPalette(analysis), [analysis]);
}
