// Port of ios/Contract/src-v1/LogCodes.kt (android/diag LogCodes.kt at contract v1).
//
// The diag log codes that carry signalling, and what each one is. For NAS the code also says which sublayer,
// which direction and whether it was ciphered on the air: a claim worth keeping apart from what the PDU says,
// because a disagreement between the two is a decoding bug worth seeing. Only signalling codes are listed.

export type Category = 'RRC' | 'NAS' | 'CELL';

/** What the log code says a record is, before the body is read. */
export interface LogCodeInfo {
  code: number;
  name: string;
  rat: 'lte' | 'nr';
  category: Category;
  /** For NAS: the sublayer the code claims. */
  nasSublayer: string | null;
  /** For NAS: 'ul' when the modem sent it, 'dl' when it received it. */
  nasDirection: 'ul' | 'dl' | null;
  /** For NAS: true when the message was security protected on the air. */
  nasProtected: boolean;
  isNr: boolean;
}

const info = (
  code: number,
  name: string,
  rat: 'lte' | 'nr',
  category: Category,
  nasSublayer: string | null = null,
  nasDirection: 'ul' | 'dl' | null = null,
  nasProtected = false,
): LogCodeInfo => ({ code, name, rat, category, nasSublayer, nasDirection, nasProtected, isNr: rat === 'nr' });

const rrc = (code: number, name: string, rat: 'lte' | 'nr') => info(code, name, rat, 'RRC');
const cell = (code: number, name: string, rat: 'lte' | 'nr') => info(code, name, rat, 'CELL');
const nas = (code: number, name: string, rat: 'lte' | 'nr', sub: string, dir: 'ul' | 'dl', prot: boolean) =>
  info(code, name, rat, 'NAS', sub, dir, prot);

const ALL: readonly LogCodeInfo[] = [
  // LTE RRC and cell identity
  rrc(0xb0c0, 'LTE RRC OTA Packet', 'lte'),
  cell(0xb0c1, 'LTE RRC MIB Message Log Packet', 'lte'),
  cell(0xb0c2, 'LTE RRC Serving Cell Info Log Packet', 'lte'),
  // LTE NAS. "Incoming" is from the network, so downlink.
  nas(0xb0e0, 'LTE NAS ESM Security Protected Incoming Msg', 'lte', 'esm', 'dl', true),
  nas(0xb0e1, 'LTE NAS ESM Security Protected Outgoing Msg', 'lte', 'esm', 'ul', true),
  nas(0xb0e2, 'LTE NAS ESM Plain OTA Incoming Msg', 'lte', 'esm', 'dl', false),
  nas(0xb0e3, 'LTE NAS ESM Plain OTA Outgoing Msg', 'lte', 'esm', 'ul', false),
  nas(0xb0ea, 'LTE NAS EMM Security Protected Incoming Msg', 'lte', 'emm', 'dl', true),
  nas(0xb0eb, 'LTE NAS EMM Security Protected Outgoing Msg', 'lte', 'emm', 'ul', true),
  nas(0xb0ec, 'LTE NAS EMM Plain OTA Incoming Msg', 'lte', 'emm', 'dl', false),
  nas(0xb0ed, 'LTE NAS EMM Plain OTA Outgoing Msg', 'lte', 'emm', 'ul', false),
  // NR NAS
  nas(0xb800, 'NR NAS SM5G Plain OTA Incoming Msg', 'nr', '5gsm', 'dl', false),
  nas(0xb801, 'NR NAS SM5G Plain OTA Outgoing Msg', 'nr', '5gsm', 'ul', false),
  nas(0xb808, 'NR NAS SM5G Security Protected Incoming Msg', 'nr', '5gsm', 'dl', true),
  nas(0xb809, 'NR NAS SM5G Security Protected Outgoing Msg', 'nr', '5gsm', 'ul', true),
  nas(0xb80a, 'NR NAS MM5G Plain OTA Incoming Msg', 'nr', '5gmm', 'dl', false),
  nas(0xb80b, 'NR NAS MM5G Plain OTA Outgoing Msg', 'nr', '5gmm', 'ul', false),
  nas(0xb80c, 'NR NAS MM5G Security Protected Incoming Msg', 'nr', '5gmm', 'dl', true),
  nas(0xb80d, 'NR NAS MM5G Security Protected Outgoing Msg', 'nr', '5gmm', 'ul', true),
  // NR RRC and cell identity
  rrc(0xb821, 'NR RRC OTA Packet', 'nr'),
  cell(0xb822, 'NR RRC MIB Info', 'nr'),
  cell(0xb823, 'NR RRC Serving Cell Info', 'nr'),
];

const BY_CODE = new Map(ALL.map((i) => [i.code, i]));

/** What `code` is, or null when it is not a signalling code. */
export const logCodeOf = (code: number): LogCodeInfo | null => BY_CODE.get(code) ?? null;

/** Every signalling code, for building a capture's log mask. */
export const allLogCodes = (): readonly LogCodeInfo[] => ALL;

/** The codes a signalling capture should enable. */
export const signallingCodes = (): number[] => ALL.map((i) => i.code);
