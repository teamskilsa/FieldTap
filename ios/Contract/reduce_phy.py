#!/usr/bin/env python3
"""Reduce phy-inventory/kpis.json (reference PHY extractor output, Unix seconds) to the contract fixtures the
Swift FTPhy / FTJourney packages are tested against. Times become ms since the CallFlow time base (first
plausible modem timestamp; for this capture 1_790_019_725.984205 s = event 0 raw minus sinceStartMs).

  phy-golden.json   per KPI: unit, code, count, min, max, mean (per-Rx arrays per index), first/last 3 samples
  phy-summary.json  what FTJourney needs: SCell activity, NR DL activity, RACH/TA events, antennas, encrypted census
Usage: reduce_phy.py <kpis.json> <callflow-golden.json> <outdir>
"""
import json, sys, statistics as st, collections

kp = json.load(open(sys.argv[1]))['kpis']
g = json.load(open(sys.argv[2]))
out = sys.argv[3]
e0 = g['events'][0]
def modem_ms(raw): return (raw >> 16) * 1.25 + (raw & 0xFFFF) / 39321.6
start_ms_gps = modem_ms(e0['timestampRaw']) - e0['sinceStartMs']
UNIX0 = (315_964_800_000 + start_ms_gps) / 1000.0
def rel(t): return round(t * 1000 - UNIX0 * 1000, 1)

def stats(vals):
    v = [x for x in vals if x is not None]
    if not v: return {'count': 0}
    return {'count': len(v), 'min': round(min(v), 4), 'max': round(max(v), 4), 'mean': round(st.fmean(v), 4)}

golden = {'timeBase': {'unixStart': UNIX0, 'rule': 'first plausible (>=2005) modem timestamp, as CallFlow D1'}, 'kpis': {}}
for name, k in kp.items():
    s = k['samples']
    ent = {'unit': k['unit'], 'code': k['code'], 'samples': len(s)}
    if s and isinstance(s[0]['value'], list):
        n = max(len(x['value']) for x in s)
        ent['perIndex'] = [stats([x['value'][i] if i < len(x['value']) else None for x in s]) for i in range(n)]
    else:
        ent.update(stats([x['value'] for x in s if isinstance(x['value'], (int, float))]))
    def slim(x): return {'tMs': rel(x['t']), 'value': x['value']}
    ent['first'] = [slim(x) for x in s[:3]]
    ent['last'] = [slim(x) for x in s[-3:]]
    golden['kpis'][name] = ent
json.dump(golden, open(out + '/phy-golden.json', 'w'), indent=1)

# ---- summary for the journey
sc = collections.defaultdict(list)
for x in kp['lte_rsrp_per_rx']['samples']:
    if x.get('scell_idx'): sc[(x['scell_idx'], x['earfcn'], x['pci'])].append(rel(x['t']))
rx = collections.defaultdict(collections.Counter)
for x in kp['lte_rx_antennas_measured']['samples']:
    if x.get('serving') and not x.get('scell_idx'): rx[x['earfcn']][x['value']] += 1
nr = [rel(x['t']) for x in kp['nr_dl_mcs']['samples']]
summary = {
    'scellActivity': [{'index': i, 'earfcn': e, 'pci': p, 'firstMs': min(v), 'lastMs': max(v), 'records': len(v),
                       'source': '0xB193 serving records with SCell index'} for (i, e, p), v in sorted(sc.items())],
    'nrDlActivity': {'index': 0, 'earfcn': 174770, 'pci': 80, 'firstMs': min(nr), 'lastMs': max(nr), 'records': len(nr), 'source': '0xB887'},
    'rach': [{'tMs': rel(x['t']), 'ta': x['value'], 'distanceM': x.get('distance_m'), 'ulEarfcn': x.get('ul_earfcn')}
             for x in kp['lte_timing_advance_rar']['samples']],
    'txAntennasMib': sorted({x['value'] for x in kp['lte_tx_antennas_mib']['samples']}),
    'rxAntennasByEarfcn': {str(e): dict(c) for e, c in sorted(rx.items())},
    'encrypted': {'records': 23764, 'codes': 61},  # qdss_deframe.py stats packets.secure; phy-inventory inventory.tsv
}
json.dump(summary, open(out + '/phy-summary.json', 'w'), indent=1)
print(json.dumps(summary)[:1500])
