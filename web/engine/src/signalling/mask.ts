// Port of the masking in ios/Contract/tools/GoldenDump.kt ('Masking' in CONTRACT.md; Swift FTModel Redaction):
// used both to write goldens and to give the UI the masked form of every string it shows while identifiers are
// hidden. JavaScript's \d, \b and the 'i' flag are ASCII-only here, as Java's are by default.

/** A field whose label matches is masked, and so is every field under it. */
export const IDENTITY_LABEL = new RegExp(
  '(^identity$|imsi|imei|tmsi|guti|suci|supi|msisdn|mobile identity|ue identity|i-rnti|s-tmsi|random ?value|' +
    'address|\\bip\\b|ipv4|ipv6|dns|p-cscf|pcscf|interface identifier|cell identity|\\bnci\\b|\\beci\\b)',
  'i',
);

/** Applied to every other string, in this order (Kotlin's Regex.replace is global). */
const SCRUBS: RegExp[] = [
  /\b([0-9a-f]{1,4}:){2,7}[0-9a-f:]{1,4}\b|::[0-9a-f]{1,4}/gi, // IPv6
  /\b\d{1,3}(\.\d{1,3}){3}\b/g, // IPv4
  /\+?\d[\d ]{8,}\d/g, // IMSI / IMEI / MSISDN-like runs of 10+ digits
  /0x[0-9a-f]{8,}/gi, // TMSI and other identities printed as hex
];

export const MASKED = '<masked>';

/** `s` with IP addresses, long digit runs and long hex replaced by '<masked>'. */
export function scrub(s: string): string {
  let t = s;
  for (const r of SCRUBS) t = t.replace(r, MASKED);
  return t;
}

export const scrubNullable = (s: string | null): string | null => (s === null ? null : scrub(s));

export const isIdentityLabel = (label: string) => IDENTITY_LABEL.test(label);

export interface MaskableField {
  label: string;
  value: string;
  children: MaskableField[];
}

/**
 * The masked value of one field: '<masked>' for an identity-labelled leaf (or any leaf under one); an identity
 * field with children keeps its own value scrubbed ('Identity: GUTI' still says which identity it was); every
 * other value is scrubbed. `masked` says whether the field is identity-labelled (or under one).
 */
export function maskedValue(field: MaskableField, parentMasked: boolean): { value: string; masked: boolean } {
  const masked = parentMasked || isIdentityLabel(field.label);
  return { value: masked && field.children.length === 0 ? MASKED : scrub(field.value), masked };
}

/** GoldenDump.maskField: the field and everything under it, masked. */
export function maskField<F extends MaskableField>(field: F, parentMasked = false): MaskableField {
  const { value, masked } = maskedValue(field, parentMasked);
  return { label: field.label, value, children: field.children.map((c) => maskField(c, masked)) };
}
