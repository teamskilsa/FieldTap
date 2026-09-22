// Apple's Baseband logging profile as the archive records it, and the Modem logging guide state that follows.
// A website cannot look at a phone's installed profiles, so the sysdiagnose is the evidence: its
// logs/MCState/Shared/profile-*.stub records (the one whose PayloadIdentifier is com.apple.basebandlogging), and
// logs/Baseband/ambtool_output.log. Ports FTModel/CaptureGuideState.swift and ProfileState.status(at:).

import type { GuideState, ImportProblem, ProfileState } from '../types.ts';
import { isDict, parsePlist, PlistDate, type PlistValue } from './plist.ts';

export const BASEBAND_PROFILE = 'com.apple.basebandlogging';
/** Less than this much time left counts as 'expires soon'. */
export const EXPIRING_SOON_MS = 24 * 60 * 60 * 1000;
const DAY_MS = 86_400_000;

/** What one stub says, before any judgement. */
export interface ProfileRecord {
  identifier?: string;
  displayName?: string;
  installMs?: number;
  removalMs?: number;
}

/** The stub's identity and dates; null when it is not a readable plist dictionary. */
export function readProfileStub(bytes: Uint8Array): ProfileRecord | null {
  let root: PlistValue;
  try {
    root = parsePlist(bytes);
  } catch {
    return null;
  }
  if (!isDict(root)) return null;
  const str = (v: PlistValue | undefined) => (typeof v === 'string' ? v : undefined);
  const date = (v: PlistValue | undefined) => (v instanceof PlistDate ? v.ms : undefined);
  return {
    identifier: str(root.PayloadIdentifier),
    displayName: str(root.PayloadDisplayName),
    installMs: date(root.InstallDate),
    removalMs: date(root.RemovalDate),
  };
}

/**
 * The Baseband profile among the archive's stubs, judged at `observedAtMs` (the button press). Other profiles'
 * stubs are ignored; with no Baseband stub the status is 'missing'.
 */
export function profileState(stubs: Uint8Array[], observedAtMs: number | null): ProfileState {
  const observedAt = observedAtMs === null ? undefined : iso(observedAtMs);
  let unreadable = false;
  for (const bytes of stubs) {
    const record = readProfileStub(bytes);
    if (!record) {
      unreadable = true;
      continue;
    }
    if (record.identifier !== BASEBAND_PROFILE) continue;
    const state: ProfileState = {
      status: 'unknown',
      identifier: record.identifier,
      displayName: record.displayName,
      installDate: record.installMs === undefined ? undefined : iso(record.installMs),
      removalDate: record.removalMs === undefined ? undefined : iso(record.removalMs),
      lifetimeDays: record.installMs !== undefined && record.removalMs !== undefined
        ? (record.removalMs - record.installMs) / DAY_MS
        : undefined,
      observedAt,
    };
    state.status = observedAtMs === null ? 'unknown' : statusAt(record.removalMs, observedAtMs);
    return dropUndefined(state);
  }
  // An unreadable stub might have been the Baseband one: say 'unknown' rather than 'missing'.
  return dropUndefined({ status: unreadable ? 'unknown' : 'missing', observedAt });
}

/** active / expiringSoon / expired at `atMs`, from the removal date. */
export function statusAt(removalMs: number | undefined, atMs: number): ProfileState['status'] {
  if (removalMs === undefined) return 'unknown';
  if (removalMs <= atMs) return 'expired';
  if (removalMs - atMs <= EXPIRING_SOON_MS) return 'expiringSoon';
  return 'active';
}

/**
 * What logs/Baseband/ambtool_output.log says about modem logging: false for 'Baseband logs are not enabled',
 * true for a successful collection, undefined when absent or unrecognised.
 */
export function ambtoolLoggingEnabled(text: string | undefined): boolean | undefined {
  if (text === undefined) return undefined;
  if (/baseband logs are not enabled/i.test(text)) return false;
  if (/baseband log collection:\s*success/i.test(text)) return true;
  return undefined;
}

export interface GuideInput {
  profile: ProfileState;
  /** A qdss directory with chunks was in the archive. */
  hasTrace: boolean;
  loggingEnabled: boolean | undefined;
  /** The file was not a readable sysdiagnose (notASysdiagnose, truncatedArchive). */
  unreadable: boolean;
}

/** The guide state at `nowMs`, from this archive alone (GuideState.from in Swift). */
export function guideState(input: GuideInput, nowMs: number): GuideState {
  const evaluatedAt = iso(nowMs);
  const make = (status: GuideState['status'], removalMs?: number): GuideState =>
    dropUndefined({
      status,
      removalDate: removalMs === undefined ? undefined : iso(removalMs),
      daysLeft: removalMs === undefined ? undefined : Math.max(0, Math.floor((removalMs - nowMs) / DAY_MS)),
      needsAttention: status === 'off' || status === 'expired' || status === 'expiringSoon' ||
        status === 'installedNoTrace',
      evaluatedAt,
    });
  if (input.unreadable) return make('unknown');
  const { profile } = input;
  if (profile.status === 'missing') return make('off');
  const removalMs = profile.removalDate === undefined ? undefined : Date.parse(profile.removalDate);
  if (removalMs !== undefined && removalMs <= nowMs) return make('expired', removalMs);
  if (profile.status === 'expired') return make('expired', removalMs);
  if (!input.hasTrace || input.loggingEnabled === false) return make('installedNoTrace');
  if (removalMs === undefined) return make('unknown');
  if (removalMs - nowMs <= EXPIRING_SOON_MS) return make('expiringSoon', removalMs);
  return make('active', removalMs);
}

export interface ProblemInput {
  profile: ProfileState;
  hasTrace: boolean;
  loggingEnabled: boolean | undefined;
  /** UTC ms of the first file info.txt lists: when the modem's trace began. */
  traceBeganMs: number | null;
  /** Listed files missing inside the kept window. */
  filesMissing: number;
  /** The trace directory holds chunks but no info.txt. */
  noInfoTxt: boolean;
}

/** What the user should know about this archive's profile and trace, blocking problems first. */
export function profileProblems(p: ProblemInput): ImportProblem[] {
  const out: ImportProblem[] = [];
  const hasStub = p.profile.status !== 'missing';
  if (p.loggingEnabled === false) {
    out.push(problem('loggingNotEnabled', 'The sysdiagnose says baseband logging was not enabled.', !p.hasTrace));
  }
  if (!p.hasTrace && !hasStub) {
    out.push(problem('noBasebandTrace', 'No modem trace in this sysdiagnose: the Baseband logging profile was not installed.', true));
  } else if (!p.hasTrace && p.profile.status !== 'expired') {
    out.push(problem('profileInstalledNoTrace', 'The logging profile was installed but no modem trace was recorded. Restart the iPhone and take a new sysdiagnose.', true));
  }
  if (p.profile.status === 'expired') {
    out.push(problem('profileExpired', 'The Baseband logging profile had expired when this sysdiagnose was taken.', !p.hasTrace, p.profile.removalDate));
  } else if (p.profile.status === 'expiringSoon') {
    out.push(problem('profileExpiresSoon', 'The Baseband logging profile expired within a day of this sysdiagnose.', false, p.profile.removalDate));
  }
  if (p.hasTrace && !hasStub) {
    out.push(problem('profileMissing', 'There is a modem trace but no Baseband logging profile record in this sysdiagnose.', false));
  }
  if (p.hasTrace && p.profile.installDate && p.traceBeganMs !== null &&
    Date.parse(p.profile.installDate) > p.traceBeganMs + 1000) {
    out.push(problem('profileInstalledAfterTrace', 'The logging profile was installed after this trace began, so the trace predates it.', false));
  }
  if (p.noInfoTxt) {
    out.push({ ...problem('unsupportedTrace', 'The trace has no info.txt, so its time window is unknown.', false), detail: 'no info.txt' });
  }
  if (p.filesMissing > 0) {
    out.push({
      ...problem('traceGaps', `${p.filesMissing} trace ${p.filesMissing === 1 ? 'file is' : 'files are'} missing inside the kept window; messages around ${p.filesMissing === 1 ? 'it' : 'them'} may be incomplete.`, false),
      detail: String(p.filesMissing),
    });
  }
  return out.sort((a, b) => Number(b.blocking) - Number(a.blocking));
}

export function problem(kind: ImportProblem['kind'], message: string, blocking: boolean, date?: string): ImportProblem {
  return dropUndefined({ kind, message, blocking, date });
}

export const iso = (ms: number) => new Date(ms).toISOString();

/** Optional fields are left out rather than set to undefined, so results compare and serialise cleanly. */
export function dropUndefined<T extends object>(o: T): T {
  for (const k of Object.keys(o) as (keyof T)[]) if (o[k] === undefined) delete o[k];
  return o;
}
