// The security check must fire on each IMSI-catcher signature with the right severity, and stay silent on a clean
// capture. The synthetic fixtures (tests/security_support.ts) are invented; the real-capture parity is in
// security_real_test.ts, gated on the real analysis being present.

import { assert, assertEquals } from './assert.ts';
import { analyzeSecurity } from '../src/security/report.ts';
import type { SecurityCheckId, SecurityReport } from '../src/types.ts';
import {
  abnormalRejectCapture,
  cleanCapture,
  downgrade2gCapture,
  imsiInClearCapture,
  noAuthCapture,
  noSecurityCapture,
  nullCipherCapture,
  orphanCellCapture,
  strongSignalCapture,
} from './security_support.ts';

const checks = (r: SecurityReport): SecurityCheckId[] => [...r.cells.flatMap((c) => c.findings), ...r.findings].map((f) => f.check);
function only(r: SecurityReport, check: SecurityCheckId): void {
  const fired = checks(r);
  assert(fired.includes(check), `expected ${check}, got [${fired.join(', ')}]`);
  const others = fired.filter((c) => c !== check);
  assertEquals(others, [], `no other check should fire, got [${others.join(', ')}]`);
}

Deno.test('clean capture: trusted, no findings', () => {
  const r = analyzeSecurity(cleanCapture());
  assertEquals(r.verdict, 'trusted');
  assertEquals(checks(r), []);
  assertEquals(r.cells, []);
  // The ruleset and the gaps are always reported, even when clean.
  assertEquals(r.ruleset, 'fieldtap-security/1');
  assert(r.gaps.length >= 1, 'unsupported checks are documented');
});

Deno.test('null ciphering (EEA0/EIA0) fires nullCipher, suspicious', () => {
  const r = analyzeSecurity(nullCipherCapture());
  only(r, 'nullCipher');
  assertEquals(r.verdict, 'suspicious');
  const f = [...r.cells.flatMap((c) => c.findings), ...r.findings].find((x) => x.check === 'nullCipher')!;
  assertEquals(f.severity, 'suspicious');
  assert(f.evidence.some((e) => e.includes('EEA0')), 'cites EEA0');
});

Deno.test('IMSI identity request before security fires imsiRequestedInClear, suspicious', () => {
  const r = analyzeSecurity(imsiInClearCapture());
  only(r, 'imsiRequestedInClear');
  assertEquals(r.verdict, 'suspicious');
});

Deno.test('IMEISV identity request is NOT flagged (the reference-capture case)', () => {
  // cleanCapture asks for IMEISV; imsiInClear asks for IMSI. Only the second fires.
  assertEquals(checks(analyzeSecurity(cleanCapture())).includes('imsiRequestedInClear'), false);
});

Deno.test('forced 2G redirect fires ratDowngrade, suspicious', () => {
  const r = analyzeSecurity(downgrade2gCapture());
  only(r, 'ratDowngrade');
  assertEquals(r.verdict, 'suspicious');
});

Deno.test('accept with no auth and no context fires acceptedWithoutAuth, suspicious', () => {
  const r = analyzeSecurity(noAuthCapture());
  only(r, 'acceptedWithoutAuth');
  assertEquals(r.verdict, 'suspicious');
});

Deno.test('accept with no Security Mode Command fires noSecurityEstablished, suspicious', () => {
  const r = analyzeSecurity(noSecurityCapture());
  only(r, 'noSecurityEstablished');
  assertEquals(r.verdict, 'suspicious');
});

Deno.test('network-stranding reject cause fires abnormalReject, suspicious', () => {
  const r = analyzeSecurity(abnormalRejectCapture());
  only(r, 'abnormalReject');
  assertEquals(r.verdict, 'suspicious');
});

Deno.test('implausibly strong signal fires implausibleSignal, warning', () => {
  const r = analyzeSecurity(strongSignalCapture());
  only(r, 'implausibleSignal');
  assertEquals(r.verdict, 'warning');
});

Deno.test('orphan cell fires orphanCell, warning', () => {
  const r = analyzeSecurity(orphanCellCapture());
  only(r, 'orphanCell');
  assertEquals(r.verdict, 'warning');
  const f = [...r.cells.flatMap((c) => c.findings)].find((x) => x.check === 'orphanCell')!;
  assertEquals(f.cell?.pci, 22);
});

Deno.test('every finding is plain, JSON-serialisable data', () => {
  const r = analyzeSecurity(nullCipherCapture());
  assertEquals(JSON.parse(JSON.stringify(r)), r);
});
