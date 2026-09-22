#!/usr/bin/env python3
"""Structural JSON comparison for the FieldTap contract fixtures.

  json_equal.py A.json B.json [--tolerance 0.0015] [--ignore source.file ...]

Objects compare by key set and value, arrays by length and position, strings and booleans exactly, and
numbers within the tolerance (absolute) -- integers too, so the 17-digit modem timestamps compare exactly
when they are equal. Paths are dotted, with [i] for array positions; --ignore takes dotted paths without
indexes and skips them at any position (so events.cell ignores the cell of every event).
Prints 'equal' and exits 0, or prints each differing path and exits 1. GoldenCodec.jsonDiff in Swift
implements the same rules.
"""
import argparse, json, re, sys


def strip_index(path):
    return re.sub(r'\[\d+\]', '', path)


def diff(a, b, path, tol, ignore, out):
    if strip_index(path) in ignore:
        return
    if isinstance(a, bool) or isinstance(b, bool):
        if a is not b:
            out.append(path)
        return
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if isinstance(a, int) and isinstance(b, int):
            if a != b and abs(a - b) > tol:
                out.append(path)
        elif abs(float(a) - float(b)) > tol:
            out.append(path)
        return
    if type(a) is not type(b):
        out.append(path)
        return
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            p = f'{path}.{k}' if path else k
            if k not in a or k not in b:
                if strip_index(p) not in ignore:
                    out.append(p)
                continue
            diff(a[k], b[k], p, tol, ignore, out)
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append(f'{path}.length')
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f'{path}[{i}]', tol, ignore, out)
    elif a != b:
        out.append(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a')
    ap.add_argument('b')
    ap.add_argument('--tolerance', type=float, default=0.0015)
    ap.add_argument('--ignore', action='append', default=[])
    args = ap.parse_args()
    a = json.load(open(args.a))
    b = json.load(open(args.b))
    out = []
    diff(a, b, '', args.tolerance, set(args.ignore), out)
    if out:
        for p in out[:200]:
            print(p)
        print(f'{len(out)} differences')
        sys.exit(1)
    print('equal')


if __name__ == '__main__':
    main()
