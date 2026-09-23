// OWNER: security. DESIGN ONLY — this file defines the *interface* for an optional external cell-database
// cross-check and contains no implementation that touches the network. It is deliberately not wired into
// analyzeSecurity or the default pipeline. Nothing here is called by default, and tests/policy_test.ts still
// finds no `fetch` in src/ because there is none.
//
// WHY IT IS OPT-IN AND OFF BY DEFAULT
// The whole app promises that nothing leaves the device. A cell-database lookup breaks that promise: to ask
// "is this (MCC, MNC, TAC, cell id) a known cell here?" you must send those coarse cell identifiers to a
// third-party service. That is a location-revealing request. So any implementation MUST:
//   1. be disabled by default (`enabled: false`);
//   2. require an explicit, per-session consent from the user before the first request;
//   3. send only the coarse cell identity (never IMSI/IMEI/GUTI/TMSI, never PHY samples, never the trace);
//   4. state clearly, in the UI, that enabling it sends cell IDs off-device.
//
// LICENSING / SOURCES (documented so a later implementer inherits the constraints, not just the code)
//   - OpenCelliD (https://opencellid.org): community cell database, licensed CC-BY-SA 4.0. Usable with
//     attribution and share-alike; an API key is required and rate limits apply. This is the clean, documented
//     option.
//   - Apple ALS (Apple Location Services, `gs-loc.apple.com`): an undocumented endpoint that returns nearby
//     cells for a given cell. It is what CellGuard uses. It has NO public licence or terms for this use — it is
//     a gray area, may change or block without notice, and must be treated as unsupported. Note it, do not rely
//     on it, and prefer OpenCelliD.
//   - Mozilla Location Service is retired and should not be used.
//
// HOW IT WOULD PLUG IN (when someone builds it, behind consent)
//   const provider: CellDatabaseProvider = makeOpenCelliDProvider({ apiKey, consent });
//   const external = await crossCheckCells(report, analysis, provider);   // adds `externalKnown: false` findings
// The result would only ever *raise* a cell's suspicion (an unknown cell is more suspect), never lower it: an
// absent database entry is not proof of a catcher, and a present one is not proof of safety.

import type { CaptureAnalysis, Cell, SecurityFinding } from '../types.ts';

/** The coarse identity of a cell — the only thing an external lookup is ever allowed to send. */
export interface CoarseCellId {
  /** Mobile country code, e.g. 310. */
  mcc: number;
  /** Mobile network code, e.g. 410. */
  mnc: number;
  /** Tracking area code. */
  tac: number;
  /** The cell identity (ECI/NCI), when known. */
  cellId?: number | undefined;
  earfcn: number;
  pci: number;
  rat: 'LTE' | 'NR';
}

/** What a lookup returns for one cell. No coordinates are needed for the check, only "is this a known cell here". */
export interface CellDatabaseHit {
  known: boolean;
  /** The source that answered, for attribution ('OpenCelliD'). */
  source: string;
}

/**
 * An external cell-database provider. A real one performs a network request and therefore may only be constructed
 * behind explicit consent; it is intentionally NOT implemented in this file. `enabled` and `consentGiven` are on
 * the interface so a caller cannot forget them.
 */
export interface CellDatabaseProvider {
  readonly name: string;
  readonly enabled: boolean;
  readonly consentGiven: boolean;
  lookup(cell: CoarseCellId): Promise<CellDatabaseHit>;
}

export interface ExternalCrossCheckOptions {
  provider: CellDatabaseProvider;
}

/**
 * The opt-in cross-check. It refuses to do anything unless the provider is both enabled and consented, so the
 * default (no provider, or a provider with consent withheld) makes no request. A concrete provider is out of
 * scope here on purpose; this function only defines the contract and the guard.
 */
export function crossCheckCells(
  _report: unknown,
  _analysis: CaptureAnalysis,
  options: ExternalCrossCheckOptions,
): Promise<SecurityFinding[]> {
  const { provider } = options;
  if (!provider.enabled || !provider.consentGiven) {
    // The privacy-preserving default: do nothing and send nothing.
    return Promise.resolve([]);
  }
  // A real implementation would build a CoarseCellId per cell and call provider.lookup here, behind the consent
  // gate above. It is not implemented, so that src/ contains no network call and the promise stays honest.
  throw new Error('External cell-database cross-check is not implemented: this is a design-only interface.');
}

/** Build the coarse identity the lookup is allowed to send, from a decoded serving-cell detail. Pure. */
export function coarseCellId(cell: Cell, detail: { plmn: string; tac: number; cellIdentity?: number | undefined }): CoarseCellId | null {
  const [mccStr, mncStr] = detail.plmn.split('-');
  const mcc = Number(mccStr);
  const mnc = Number(mncStr);
  if (!Number.isFinite(mcc) || !Number.isFinite(mnc)) return null;
  const id: CoarseCellId = { mcc, mnc, tac: detail.tac, earfcn: cell.earfcn, pci: cell.pci, rat: cell.nr ? 'NR' : 'LTE' };
  if (detail.cellIdentity != null) id.cellId = detail.cellIdentity;
  return id;
}
