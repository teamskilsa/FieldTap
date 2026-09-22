// The words and numbers the journey's markers, findings and tiles share (FTJourney's JourneyText.swift), so the
// strip, the popovers and "What happened" say the same thing the same way. Decimals use Java's rounding
// (signalling/javafmt.ts), as the ladder's strings do.

import { fixed } from '../signalling/javafmt.ts';
import { sinceStart } from '../signalling/presentation.ts';
import type { Cell, Journey, JourneyCell, Marker } from '../types.ts';
import { sameCell } from './context.ts';

/** '0:15.040': minutes, then seconds to the millisecond, since the capture start (the ladder's clock). */
export const clock = (ms: number): string => sinceStart(Number.isFinite(ms) ? ms : 0);

/** '0:19': whole seconds, for times the user reads against a stopwatch (the window after the button press). */
export function shortClock(s: number): string {
  const total = Math.floor(Math.max(0, Number.isFinite(s) ? s : 0));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

/** '44 ms', '12.7 s', '1:05': the findings' reading of a span (the tiles use the ladder's duration()). */
export function spoken(ms: number): string {
  const v = Math.max(0, ms);
  if (v < 1_000) return `${Math.floor(v + 0.5)} ms`;
  if (v < 60_000) return `${fixed(v / 1_000, 1)} s`;
  return shortClock(v / 1_000);
}

/** '0.56 s' (two decimals under 10 s, else one). */
export const seconds = (ms: number): string => `${fixed(ms / 1_000, Math.abs(ms) < 10_000 ? 2 : 1)} s`;

/** '1.4 km', '780 m'. */
export const distance = (m: number): string => (m >= 1_000 ? `${fixed(m / 1_000, 1)} km` : `${Math.floor(m + 0.5)} m`);

/** '23,764'. */
export const count = (n: number): string => n.toLocaleString('en-US');

/** The time part of a PHY-derived id ('rach-2659.6'). */
export const idTime = (ms: number): string => fixed(ms, 1);

/** 'B66 PCI 80'; 'n5/n26 PCI 80'. */
export const shortCell = (s: JourneyCell): string => `${s.band} PCI ${s.cell.pci}`;

/** 'EARFCN' or 'NR-ARFCN'. */
export const channelName = (cell: Cell): string => (cell.nr ? 'NR-ARFCN' : 'EARFCN');

const MOVES = new Set<Marker['kind']>(['handover', 'reselection', 'reattach', 'redirect', 'reestablishment', 'cellChange']);

/** What a marker is called on its own: 'Handover B66 PCI 80 → B12 PCI 235'. */
export function markerTitle(m: Marker, journey: Pick<Journey, 'cells'>): string {
  if (!MOVES.has(m.kind)) return m.title;
  const from = m.from ? segmentBefore(m.from, m.tMs, journey.cells) : undefined;
  const to = m.to ? segmentAfter(m.to, m.tMs, journey.cells) : undefined;
  return from && to ? `${m.title} ${shortCell(from)} → ${shortCell(to)}` : m.title;
}

/** The PCell segment of `cell` that starts at or before `t` (the cell a move left). */
function segmentBefore(cell: Cell, t: number, cells: readonly JourneyCell[]): JourneyCell | undefined {
  const here = cells.filter((c) => c.lane === 'pcell' && sameCell(c.cell, cell) && c.startMs <= t + 0.5);
  return here[here.length - 1] ?? cells.find((c) => sameCell(c.cell, cell));
}

/** The PCell segment of `cell` that ends at or after `t` (the cell a move reached). */
function segmentAfter(cell: Cell, t: number, cells: readonly JourneyCell[]): JourneyCell | undefined {
  return cells.find((c) => c.lane === 'pcell' && sameCell(c.cell, cell) && c.endMs >= t - 0.5) ?? cells.find((c) => sameCell(c.cell, cell));
}
