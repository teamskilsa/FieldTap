// Port of ios/Contract/src-v1/NasNames.kt: the names 3GPP gives NAS message types and causes.
//
// Message names and directions are the table of fieldtap/decode/msgnames.py, so a session reads the same in
// every app. EMM and ESM causes are TS 24.301 (9.9.3.9 and 9.9.4.4); 5GMM and 5GSM causes TS 24.501 (9.11.3.2
// and 9.11.4.2).

type Direction = 'ul' | 'dl' | null;

const MESSAGES = new Map<string, [string, Direction]>();
const put = (layer: string, type: number, name: string, direction: Direction) => MESSAGES.set(`${layer}/${type}`, [name, direction]);

// EPS mobility management
put('emm', 0x41, 'Attach request', 'ul'); put('emm', 0x42, 'Attach accept', 'dl');
put('emm', 0x43, 'Attach complete', 'ul'); put('emm', 0x44, 'Attach reject', 'dl');
put('emm', 0x45, 'Detach request', null); put('emm', 0x46, 'Detach accept', null);
put('emm', 0x48, 'Tracking area update request', 'ul');
put('emm', 0x49, 'Tracking area update accept', 'dl');
put('emm', 0x4a, 'Tracking area update complete', 'ul');
put('emm', 0x4b, 'Tracking area update reject', 'dl');
put('emm', 0x4c, 'Extended service request', 'ul');
put('emm', 0x4d, 'Control plane service request', 'ul');
put('emm', 0x4e, 'Service reject', 'dl'); put('emm', 0x4f, 'Service accept', 'dl');
put('emm', 0x50, 'GUTI reallocation command', 'dl');
put('emm', 0x51, 'GUTI reallocation complete', 'ul');
put('emm', 0x52, 'Authentication request', 'dl');
put('emm', 0x53, 'Authentication response', 'ul');
put('emm', 0x54, 'Authentication reject', 'dl'); put('emm', 0x55, 'Identity request', 'dl');
put('emm', 0x56, 'Identity response', 'ul'); put('emm', 0x5c, 'Authentication failure', 'ul');
put('emm', 0x5d, 'Security mode command', 'dl');
put('emm', 0x5e, 'Security mode complete', 'ul');
put('emm', 0x5f, 'Security mode reject', 'ul'); put('emm', 0x60, 'EMM status', null);
put('emm', 0x61, 'EMM information', 'dl'); put('emm', 0x62, 'Downlink NAS transport', 'dl');
put('emm', 0x63, 'Uplink NAS transport', 'ul');
put('emm', 0x64, 'CS service notification', 'dl');
put('emm', 0x68, 'Downlink generic NAS transport', 'dl');
put('emm', 0x69, 'Uplink generic NAS transport', 'ul');
// EPS session management
put('esm', 0xc1, 'Activate default EPS bearer context request', 'dl');
put('esm', 0xc2, 'Activate default EPS bearer context accept', 'ul');
put('esm', 0xc3, 'Activate default EPS bearer context reject', 'ul');
put('esm', 0xc5, 'Activate dedicated EPS bearer context request', 'dl');
put('esm', 0xc6, 'Activate dedicated EPS bearer context accept', 'ul');
put('esm', 0xc7, 'Activate dedicated EPS bearer context reject', 'ul');
put('esm', 0xc9, 'Modify EPS bearer context request', 'dl');
put('esm', 0xca, 'Modify EPS bearer context accept', 'ul');
put('esm', 0xcb, 'Modify EPS bearer context reject', 'ul');
put('esm', 0xcd, 'Deactivate EPS bearer context request', 'dl');
put('esm', 0xce, 'Deactivate EPS bearer context accept', 'ul');
put('esm', 0xd0, 'PDN connectivity request', 'ul');
put('esm', 0xd1, 'PDN connectivity reject', 'dl');
put('esm', 0xd2, 'PDN disconnect request', 'ul');
put('esm', 0xd3, 'PDN disconnect reject', 'dl');
put('esm', 0xd4, 'Bearer resource allocation request', 'ul');
put('esm', 0xd5, 'Bearer resource allocation reject', 'dl');
put('esm', 0xd6, 'Bearer resource modification request', 'ul');
put('esm', 0xd7, 'Bearer resource modification reject', 'dl');
put('esm', 0xd9, 'ESM information request', 'dl');
put('esm', 0xda, 'ESM information response', 'ul');
put('esm', 0xdb, 'ESM notification', 'dl'); put('esm', 0xe8, 'ESM status', null);
// 5GS mobility management
put('5gmm', 0x41, 'Registration request', 'ul');
put('5gmm', 0x42, 'Registration accept', 'dl');
put('5gmm', 0x43, 'Registration complete', 'ul');
put('5gmm', 0x44, 'Registration reject', 'dl');
put('5gmm', 0x45, 'Deregistration request (UE originating)', 'ul');
put('5gmm', 0x46, 'Deregistration accept (UE originating)', 'dl');
put('5gmm', 0x47, 'Deregistration request (UE terminated)', 'dl');
put('5gmm', 0x48, 'Deregistration accept (UE terminated)', 'ul');
put('5gmm', 0x4c, 'Service request', 'ul'); put('5gmm', 0x4d, 'Service reject', 'dl');
put('5gmm', 0x4e, 'Service accept', 'dl');
put('5gmm', 0x4f, 'Control plane service request', 'ul');
put('5gmm', 0x54, 'Configuration update command', 'dl');
put('5gmm', 0x55, 'Configuration update complete', 'ul');
put('5gmm', 0x56, 'Authentication request', 'dl');
put('5gmm', 0x57, 'Authentication response', 'ul');
put('5gmm', 0x58, 'Authentication reject', 'dl');
put('5gmm', 0x59, 'Authentication failure', 'ul');
put('5gmm', 0x5a, 'Authentication result', 'dl');
put('5gmm', 0x5b, 'Identity request', 'dl'); put('5gmm', 0x5c, 'Identity response', 'ul');
put('5gmm', 0x5d, 'Security mode command', 'dl');
put('5gmm', 0x5e, 'Security mode complete', 'ul');
put('5gmm', 0x5f, 'Security mode reject', 'ul');
put('5gmm', 0x64, '5GMM status', null); put('5gmm', 0x65, 'Notification', 'dl');
put('5gmm', 0x66, 'Notification response', 'ul');
put('5gmm', 0x67, 'UL NAS transport', 'ul'); put('5gmm', 0x68, 'DL NAS transport', 'dl');
// 5GS session management
put('5gsm', 0xc1, 'PDU session establishment request', 'ul');
put('5gsm', 0xc2, 'PDU session establishment accept', 'dl');
put('5gsm', 0xc3, 'PDU session establishment reject', 'dl');
put('5gsm', 0xc5, 'PDU session authentication command', 'dl');
put('5gsm', 0xc9, 'PDU session modification request', 'ul');
put('5gsm', 0xca, 'PDU session modification reject', 'dl');
put('5gsm', 0xd1, 'PDU session release request', 'ul');
put('5gsm', 0xd3, 'PDU session release command', 'dl');
put('5gsm', 0xd6, '5GSM status', null);

const causes = (entries: [number, string][]) => new Map(entries);

/** TS 24.301 9.9.3.9. */
const EMM_CAUSES = causes([
  [2, 'IMSI unknown in HSS'], [3, 'Illegal UE'], [5, 'IMEI not accepted'],
  [6, 'Illegal ME'], [7, 'EPS services not allowed'],
  [8, 'EPS services and non-EPS services not allowed'],
  [9, 'UE identity cannot be derived by the network'], [10, 'Implicitly detached'],
  [11, 'PLMN not allowed'], [12, 'Tracking area not allowed'],
  [13, 'Roaming not allowed in this tracking area'],
  [14, 'EPS services not allowed in this PLMN'], [15, 'No suitable cells in tracking area'],
  [16, 'MSC temporarily not reachable'], [17, 'Network failure'],
  [18, 'CS domain not available'], [19, 'ESM failure'], [20, 'MAC failure'],
  [21, 'Synch failure'], [22, 'Congestion'], [23, 'UE security capabilities mismatch'],
  [24, 'Security mode rejected, unspecified'], [25, 'Not authorized for this CSG'],
  [26, 'Non-EPS authentication unacceptable'],
  [35, 'Requested service option not authorized in this PLMN'],
  [39, 'CS service temporarily not available'], [40, 'No EPS bearer context activated'],
  [42, 'Severe network failure'], [95, 'Semantically incorrect message'],
  [96, 'Invalid mandatory information'],
  [97, 'Message type non-existent or not implemented'],
  [98, 'Message type not compatible with the protocol state'],
  [99, 'Information element non-existent or not implemented'],
  [100, 'Conditional IE error'], [101, 'Message not compatible with the protocol state'],
  [111, 'Protocol error, unspecified'],
]);

/** TS 24.501 9.11.3.2. */
const FIVE_GMM_CAUSES = causes([
  [3, 'Illegal UE'], [5, 'PEI not accepted'], [6, 'Illegal ME'],
  [7, '5GS services not allowed'], [9, 'UE identity cannot be derived by the network'],
  [10, 'Implicitly de-registered'], [11, 'PLMN not allowed'],
  [12, 'Tracking area not allowed'], [13, 'Roaming not allowed in this tracking area'],
  [15, 'No suitable cells in tracking area'], [20, 'MAC failure'], [21, 'Synch failure'],
  [22, 'Congestion'], [23, 'UE security capabilities mismatch'],
  [24, 'Security mode rejected, unspecified'], [26, 'Non-5G authentication unacceptable'],
  [27, 'N1 mode not allowed'], [28, 'Restricted service area'],
  [43, 'LADN not available'], [65, 'Maximum number of PDU sessions reached'],
  [67, 'Insufficient resources for specific slice and DNN'],
  [69, 'Insufficient resources for specific slice'], [71, 'ngKSI already in use'],
  [72, 'Non-3GPP access to 5GCN not allowed'], [73, 'Serving network not authorized'],
  [74, 'Temporarily not authorized for this SNPN'],
  [75, 'Permanently not authorized for this SNPN'],
  [76, 'Not authorized for this CAG or authorized for CAG cells only'],
  [77, 'Wireline access area not allowed'], [90, 'Payload was not forwarded'],
  [91, 'DNN not supported or not subscribed in the slice'],
  [92, 'Insufficient user-plane resources for the PDU session'],
  [95, 'Semantically incorrect message'], [96, 'Invalid mandatory information'],
  [97, 'Message type non-existent or not implemented'],
  [98, 'Message type not compatible with the protocol state'],
  [99, 'Information element non-existent or not implemented'],
  [100, 'Conditional IE error'], [101, 'Message not compatible with the protocol state'],
  [111, 'Protocol error, unspecified'],
]);

/** TS 24.301 9.9.4.4. */
const ESM_CAUSES = causes([
  [8, 'Operator determined barring'], [26, 'Insufficient resources'],
  [27, 'Missing or unknown APN'], [28, 'Unknown PDN type'],
  [29, 'User authentication failed'], [30, 'Request rejected by Serving GW or PDN GW'],
  [31, 'Request rejected, unspecified'], [32, 'Service option not supported'],
  [33, 'Requested service option not subscribed'],
  [34, 'Service option temporarily out of order'], [35, 'PTI already in use'],
  [36, 'Regular deactivation'], [37, 'EPS QoS not accepted'], [38, 'Network failure'],
  [39, 'Reactivation requested'], [50, 'PDN type IPv4 only allowed'],
  [51, 'PDN type IPv6 only allowed'], [54, 'PDN connection does not exist'],
  [55, 'Multiple PDN connections for a given APN not allowed'],
  [65, 'Maximum number of EPS bearers reached'],
]);

/** TS 24.501 9.11.4.2. */
const FIVE_GSM_CAUSES = causes([
  [8, 'Operator determined barring'], [26, 'Insufficient resources'],
  [27, 'Missing or unknown DNN'], [28, 'Unknown PDU session type'],
  [29, 'User authentication or authorization failed'],
  [31, 'Request rejected, unspecified'], [32, 'Service option not supported'],
  [33, 'Requested service option not subscribed'], [36, 'Regular deactivation'],
  [38, 'Network failure'], [39, 'Reactivation requested'],
  [50, 'PDU session type IPv4 only allowed'], [51, 'PDU session type IPv6 only allowed'],
  [54, 'PDU session does not exist'], [67, 'Insufficient resources for specific slice and DNN'],
  [69, 'Insufficient resources for specific slice'],
]);

/** The 3GPP name and direction of a message type, or nulls when the type is unknown. */
export function nasMessageName(sublayer: string, messageType: number | null): [string | null, Direction] {
  if (messageType === null) return [null, null];
  return MESSAGES.get(`${sublayer}/${messageType}`) ?? [null, null];
}

/** The 3GPP name of a cause within its sublayer, or null when it is not one we name. */
export function nasCauseName(sublayer: string, value: number): string | null {
  return CAUSES.get(sublayer)?.get(value) ?? null;
}

const CAUSES = new Map([['emm', EMM_CAUSES], ['esm', ESM_CAUSES], ['5gmm', FIVE_GMM_CAUSES], ['5gsm', FIVE_GSM_CAUSES]]);
