// OWNER: security. The security module's entry point: the local, no-network fake-base-station check, its
// thresholds, and the design-only external cross-check interface. Everything here is pure browser TypeScript.
export { analyzeSecurity } from './report.ts';
export { SECURITY_RULESET } from './thresholds.ts';
export type { CellDatabaseHit, CellDatabaseProvider, CoarseCellId } from './external.ts';
export { coarseCellId, crossCheckCells } from './external.ts';
