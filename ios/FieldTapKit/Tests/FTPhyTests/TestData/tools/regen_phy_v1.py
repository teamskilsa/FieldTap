#!/usr/bin/env python3
"""Regenerates the PHY contract fixtures under the v1 rule of ios/Contract/CONTRACT.md ("PHY parity").

The reference extractor (Fixtures/local/reference-phy/kpis.py) keys the per-second bins of lte_dl_bler,
lte_dl_phy_throughput and lte_ul_phy_throughput by a hard-coded PCell table, and takes the NR DL ARFCN from a
hard-coded NR cell. FTPhy uses only what the records carry, so the contract keys every bin by (whole UTC second,
carrier index), puts it at second + 0.5 s, and leaves the NR DL earfcn null for FTJourney to attribute. The other
45 KPIs are reduced exactly as ios/Contract/reduce_phy.py reduces them, and this script checks that they come out
identical to contract/phy-golden.json.

  regen_phy_v1.py <Fixtures/local>
writes, next to the originals (all git-ignored, never committed):
  contract/phy-golden-v1.json    48 KPIs, as phy-golden.json but with the three bin KPIs rebuilt
  contract/phy-summary-v1.json   as phy-summary.json, nrDlActivity.earfcn null, RACH preamble target power
  reference-phy/lte-tbs-reference.json
                                 the reference extractor's own copy of TS 36.213 Table 7.1.7.2.1-1 (tbs.py), the
                                 local oracle FTPhyTests checks LteTbs against; it stays in Fixtures/local
"""
import collections, json, os, statistics as st, sys

root = sys.argv[1]
kp = json.load(open(os.path.join(root, 'reference-phy/kpis.json')))['kpis']
g = json.load(open(os.path.join(root, 'contract/callflow-golden.json')))
old = json.load(open(os.path.join(root, 'contract/phy-golden.json')))
e0 = g['events'][0]
def modem_ms(raw): return (raw >> 16) * 1.25 + (raw & 0xFFFF) / 39321.6
UNIX0 = (315_964_800_000 + modem_ms(e0['timestampRaw']) - e0['sinceStartMs']) / 1000.0
def rel(t): return round(t * 1000 - UNIX0 * 1000, 1)

# ---- the three bin KPIs, keyed by (whole UTC second, carrier index)
dl = collections.defaultdict(lambda: [0, 0, 0])
for tbs, crc in zip(kp['lte_dl_tbs']['samples'], kp['lte_dl_crc_ok']['samples']):
    assert tbs['t'] == crc['t'] and tbs['cc'] == crc['cc']
    b = dl[(int(crc['t']), crc['cc'])]
    b[0] += 1; b[1] += 1 - crc['value']; b[2] += tbs['value'] * 8 if crc['value'] else 0
ul = collections.defaultdict(int)
for prb, tbs in zip(kp['lte_ul_prb']['samples'], kp['lte_ul_tbs']['samples']):
    assert prb['t'] == tbs['t']
    ul[(int(tbs['t']), prb['cc'])] += tbs['value'] * 8
bins = {
    'lte_dl_bler': [dict(t=s + 0.5, value=round(100.0 * f / n, 2), cc=cc) for (s, cc), (n, f, _) in sorted(dl.items())],
    'lte_dl_phy_throughput': [dict(t=s + 0.5, value=round(bits / 1e6, 3), cc=cc) for (s, cc), (_, _, bits) in sorted(dl.items())],
    'lte_ul_phy_throughput': [dict(t=s + 0.5, value=round(bits / 1e6, 3), cc=cc) for (s, cc), bits in sorted(ul.items())],
}

def stats(vals):
    v = [x for x in vals if x is not None]
    if not v: return {'count': 0}
    return {'count': len(v), 'min': round(min(v), 4), 'max': round(max(v), 4), 'mean': round(st.fmean(v), 4)}

golden = {'timeBase': {'unixStart': UNIX0, 'rule': 'first plausible (>=2005) modem timestamp, as CallFlow D1'},
          'binRule': 'lte_dl_bler, lte_dl_phy_throughput, lte_ul_phy_throughput: keyed by (whole UTC second, carrier '
                     'index), tMs = second + 0.5 s; no cell table (CONTRACT.md, PHY parity)',
          'kpis': {}}
for name, k in kp.items():
    s = bins.get(name, k['samples'])
    ent = {'unit': k['unit'], 'code': k['code'], 'samples': len(s)}
    if s and isinstance(s[0]['value'], list):
        n = max(len(x['value']) for x in s)
        ent['perIndex'] = [stats([x['value'][i] if i < len(x['value']) else None for x in s]) for i in range(n)]
    else:
        ent.update(stats([x['value'] for x in s if isinstance(x['value'], (int, float))]))
    ent['first'] = [{'tMs': rel(x['t']), 'value': x['value']} for x in s[:3]]
    ent['last'] = [{'tMs': rel(x['t']), 'value': x['value']} for x in s[-3:]]
    if name not in bins:
        assert ent == old['kpis'][name], name + ' differs from phy-golden.json'
    golden['kpis'][name] = ent
json.dump(golden, open(os.path.join(root, 'contract/phy-golden-v1.json'), 'w'), indent=1)

# ---- the summary FTJourney reads: record-derived only
sc = collections.defaultdict(list)
for x in kp['lte_rsrp_per_rx']['samples']:
    if x.get('scell_idx'): sc[(x['scell_idx'], x['earfcn'], x['pci'])].append(rel(x['t']))
rx = collections.defaultdict(collections.Counter)
for x in kp['lte_rx_antennas_measured']['samples']:
    if x.get('serving') and not x.get('scell_idx'): rx[x['earfcn']][x['value']] += 1
nr = [rel(x['t']) for x in kp['nr_dl_mcs']['samples']]
nr_pci = {x['pci'] for x in kp['nr_dl_mcs']['samples']}
summary = {
    'scellActivity': [{'index': i, 'earfcn': e, 'pci': p, 'firstMs': min(v), 'lastMs': max(v), 'records': len(v),
                       'source': '0xB193 serving records with SCell index'} for (i, e, p), v in sorted(sc.items())],
    'nrDlActivity': {'index': 0, 'earfcn': None, 'pci': nr_pci.pop() if len(nr_pci) == 1 else None,
                     'firstMs': min(nr), 'lastMs': max(nr), 'records': len(nr), 'source': '0xB887'},
    'rach': [{'tMs': rel(x['t']), 'ta': x['value'], 'distanceM': x.get('distance_m'), 'ulEarfcn': x.get('ul_earfcn'),
              'preambleTargetDbm': x.get('preamble_target_dbm')} for x in kp['lte_timing_advance_rar']['samples']],
    'txAntennasMib': sorted({x['value'] for x in kp['lte_tx_antennas_mib']['samples']}),
    'rxAntennasByEarfcn': {str(e): {str(n): c for n, c in sorted(cnt.items())} for e, cnt in sorted(rx.items())},
    'encrypted': {'records': 23764, 'codes': 61},
}
json.dump(summary, open(os.path.join(root, 'contract/phy-summary-v1.json'), 'w'), indent=1)
sys.path.insert(0, os.path.join(root, 'reference-phy'))
import tbs as reference_tbs   # noqa: E402
json.dump({'what': 'reference-phy tbs.py tables (local oracle; never commit)', 'tbs': reference_tbs.TBS,
           'dlMcs': reference_tbs.DL_MCS, 'dlMcs256': reference_tbs.DL_MCS_256, 'ulMcs': reference_tbs.UL_MCS},
          open(os.path.join(root, 'reference-phy/lte-tbs-reference.json'), 'w'))
for name in bins:
    print('%-24s %2d bins (phy-golden.json: %d)' % (name, len(bins[name]), old['kpis'][name]['samples']))
print('nrDlActivity', summary['nrDlActivity'])
