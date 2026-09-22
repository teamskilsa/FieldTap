#!/usr/bin/env python3
"""Compares a harness JSON file (analysis.json, scan.json or a screen report) with an expectation (WP7).

    check_sim_analysis.py ACTUAL EXPECTED [--ignore DOTTED.PATH]... [--label NAME] [--quiet]
    check_sim_analysis.py --phy-golden GOLDEN EXPECTED        # note where the golden's PHY counts differ
    check_sim_analysis.py --update-phy-from GOLDEN EXPECTED   # rewrite EXPECTED's phy.samples from a golden

Exit 0 when ACTUAL meets every expectation, 1 on any difference (each printed with its dotted path), 2 when a
file cannot be read. EXPECTED is a subset of ACTUAL's shape: keys starting with '_' are comments, keys ACTUAL
has and EXPECTED lacks are not checked. Values:

- objects: every expected key must match (extra actual keys are fine); lists: same length, position by position
- numbers: within 0.0015 (the goldens print 3 decimals); integers too. A boolean never equals a number
- strings and booleans: exactly
- operators (an object whose only keys start with '$', plus "tol"):
    {"$exact": {...}}             an object with exactly these keys (count maps: an extra kind is a difference)
    {"$approx": X, "tol": T}      |actual - X| <= T
    {"$min": A} / {"$max": B}     bounds, either or both
    {"$present": true|false}      the key exists (and is not null) or does not
    {"$oneOf": [A, B, ...]}       equal to one of them
    {"$multiset": [...]}          a list with the same items in any order
    {"$contains": [...]}          a list holding at least these items (with multiplicity)
    {"$len": N}                   a list or object of that size
    {"$unique": true}             a list without repeats
"""
import json
import sys

TOL = 0.0015


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def fmt(v):
    s = json.dumps(v, sort_keys=True)
    return s if len(s) <= 160 else s[:157] + '...'


def equal(a, e):
    if is_num(e):
        return is_num(a) and abs(a - e) <= TOL
    if isinstance(e, bool) or e is None or isinstance(e, str):
        return type(a) is type(e) and a == e
    if isinstance(e, list):
        return isinstance(a, list) and len(a) == len(e) and all(equal(x, y) for x, y in zip(a, e))
    if isinstance(e, dict):
        return isinstance(a, dict) and set(a) == set(e) and all(equal(a[k], e[k]) for k in e)
    return a == e


def is_op(e):
    return isinstance(e, dict) and e and all(k.startswith('$') or k == 'tol' for k in e) \
        and any(k.startswith('$') for k in e)


def multiset_contains(actual, wanted):
    left = list(actual)
    for w in wanted:
        hit = next((i for i, a in enumerate(left) if equal(a, w)), None)
        if hit is None:
            return False
        left.pop(hit)
    return True


class Checker:
    def __init__(self, ignore=()):
        self.ignore = set(ignore)
        self.diffs = []
        self.checked = 0

    def diff(self, path, want, got):
        self.diffs.append(f'{path or "<root>"}: expected {want}, got {got}')

    def check(self, a, e, path='', present=True):
        if path in self.ignore:
            return
        if is_op(e):
            self.op(a, e, path, present)
            return
        self.checked += 1
        if not present:
            self.diff(path, fmt(e), 'nothing (key missing)')
        elif isinstance(e, dict):
            if not isinstance(a, dict):
                self.diff(path, 'an object', fmt(a))
                return
            self.checked -= 1
            for k, v in e.items():
                if k.startswith('_'):
                    continue
                self.check(a.get(k), v, f'{path}.{k}' if path else k, k in a)
        elif isinstance(e, list):
            if not isinstance(a, list):
                self.diff(path, fmt(e), fmt(a))
            elif len(a) != len(e):
                self.diff(path + '.length', len(e), f'{len(a)} ({fmt(a)})')
            elif all(not isinstance(x, (dict, list)) for x in e):
                if not equal(a, e):                      # a list of plain values: one line, not one per item
                    self.diff(path, fmt(e), fmt(a))
            else:
                self.checked -= 1
                for i, (x, y) in enumerate(zip(a, e)):
                    self.check(x, y, f'{path}[{i}]')
        elif not equal(a, e):
            self.diff(path, fmt(e), fmt(a))

    def op(self, a, e, path, present):
        self.checked += 1
        if '$present' in e:
            has = present and a is not None
            if has != bool(e['$present']):
                self.diff(path, 'present' if e['$present'] else 'absent', fmt(a) if has else 'absent')
            return
        if not present:
            self.diff(path, fmt(e), 'nothing (key missing)')
            return
        if '$exact' in e:
            if not equal(a, e['$exact']):
                want = e['$exact']
                if isinstance(want, dict) and isinstance(a, dict):
                    extra = sorted(set(a) - set(want))
                    missing = sorted(set(want) - set(a))
                    wrong = sorted(k for k in set(a) & set(want) if not equal(a[k], want[k]))
                    parts = ([f'extra {extra}'] if extra else []) + ([f'missing {missing}'] if missing else []) \
                        + [f'{k}: expected {fmt(want[k])}, got {fmt(a[k])}' for k in wrong]
                    self.diffs.append(f'{path}: ' + '; '.join(parts))
                else:
                    self.diff(path, fmt(want), fmt(a))
        elif '$approx' in e:
            tol = e.get('tol', TOL)
            if not is_num(a) or abs(a - e['$approx']) > tol:
                self.diff(path, f'{e["$approx"]} +/- {tol}', fmt(a))
        elif '$min' in e or '$max' in e:
            lo, hi = e.get('$min'), e.get('$max')
            if not is_num(a) or (lo is not None and a < lo) or (hi is not None and a > hi):
                self.diff(path, f'in [{lo if lo is not None else "-inf"}, {hi if hi is not None else "inf"}]', fmt(a))
        elif '$oneOf' in e:
            if not any(equal(a, x) for x in e['$oneOf']):
                self.diff(path, f'one of {fmt(e["$oneOf"])}', fmt(a))
        elif '$multiset' in e:
            want = e['$multiset']
            if not (isinstance(a, list) and len(a) == len(want) and multiset_contains(a, want)):
                self.diff(path, f'{fmt(want)} in any order', fmt(a))
        elif '$contains' in e:
            if not (isinstance(a, list) and multiset_contains(a, e['$contains'])):
                self.diff(path, f'a list containing {fmt(e["$contains"])}', fmt(a))
        elif '$len' in e:
            if not isinstance(a, (list, dict)) or len(a) != e['$len']:
                self.diff(path, f'size {e["$len"]}', f'size {len(a)}' if isinstance(a, (list, dict)) else fmt(a))
        elif '$unique' in e:
            if not isinstance(a, list) or len({json.dumps(x, sort_keys=True) for x in a}) != len(a):
                self.diff(path, 'no repeated items', fmt(a))
        else:
            self.diffs.append(f'{path}: unknown operator {sorted(e)}')


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as err:
        print(f'check_sim_analysis: cannot read {path}: {err}', file=sys.stderr)
        sys.exit(2)


def golden_samples(golden):
    return {k: v.get('samples', v.get('count')) for k, v in load(golden)['kpis'].items()}


def expected_samples(expected):
    s = load(expected).get('phy', {}).get('samples', {})
    return s.get('$exact', s)


def main(argv):
    args, ignore, label, quiet = [], [], None, False
    mode = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--ignore':
            ignore.append(argv[i + 1]); i += 2; continue
        if a == '--label':
            label = argv[i + 1]; i += 2; continue
        if a == '--quiet':
            quiet = True; i += 1; continue
        if a in ('--phy-golden', '--update-phy-from'):
            mode = a; i += 1; continue
        if a in ('-h', '--help'):
            print(__doc__); return 0
        args.append(a); i += 1
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    if mode == '--phy-golden':
        golden, exp = golden_samples(args[0]), expected_samples(args[1])
        notes = [f'{k}: golden {golden.get(k)}, expected {exp.get(k)}' for k in sorted(set(golden) | set(exp))
                 if golden.get(k) != exp.get(k)]
        for n in notes:
            print(f'check_sim_analysis: note: {n}')
        print(f'check_sim_analysis: {len(golden)} golden KPIs, {len(notes)} differ from the expectation'
              + (' (the contract rule re-bins lte_dl_bler, lte_dl_phy_throughput and lte_ul_phy_throughput'
                 ' until WP4 regenerates the golden)' if notes else ''))
        return 0
    if mode == '--update-phy-from':
        golden = golden_samples(args[0])
        doc = load(args[1])
        doc.setdefault('phy', {})['samples'] = {'$exact': dict(sorted(golden.items()))}
        with open(args[1], 'w') as f:
            json.dump(doc, f, indent=1)
            f.write('\n')
        print(f'check_sim_analysis: wrote {len(golden)} PHY sample counts into {args[1]}')
        return 0

    actual, expected = load(args[0]), load(args[1])
    c = Checker(ignore)
    c.check(actual, expected)
    name = label or args[0]
    for d in c.diffs:
        print(f'  DIFF {d}')
    if not quiet or c.diffs:
        print(f'check_sim_analysis: {name}: {c.checked} checked, {len(c.diffs)} differ')
    return 1 if c.diffs else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
