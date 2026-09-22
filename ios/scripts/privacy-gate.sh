#!/bin/zsh
# Fails when anything capture-derived or identifier-shaped would be committed from ios/, or when app code
# could reach the network.
#
#   privacy-gate.sh [--scan PATH]...
#
# Files checked: everything under ios/ that git tracks or would track (tracked + untracked-not-ignored); in a
# private copy that is not a git work tree, every file outside the ignored folders. --scan adds files or
# folders (e.g. the harness's analysis.json and screen reports) to the pattern check.
#  1. No path under Fixtures/local, and no .qmdl/.qmdl2/.bin/.stub/.tar.gz/.tgz/.pcap(ng)/.xcresult file.
#  2. No identifier shapes in text: runs of 10+ digits (numeric literals use '_' separators: 315_964_800_000;
#     md5/sha hex tokens and the all-ones sentinels 4294967295 / 2147483647 are allowed), IPv4, IPv6, and
#     0x-hex of 8+ digits (0xFFFFFFFF and QDSS chunk names like 0x0000006F.bin allowed). IPv4 shapes whose
#     octets are all single digits are 3GPP clause numbers ("5.4.2.1") and allowed. Matches are printed masked.
#  3. No networking API in ios/App or ios/FieldTapKit/Sources (and no in-app browser: R3 opens Safari).
set -euo pipefail
source "${0:A:h}/env.sh"
typeset -a EXTRA
while (( $# > 0 )); do
  case $1 in
    --scan) EXTRA+=("${2:A}"); shift 2 ;;
    *) echo "usage: $0 [--scan PATH]..." >&2; exit 2 ;;
  esac
done
cd "$FT_IOS"
if git rev-parse --show-toplevel > /dev/null 2>&1; then
  FILES=$(git ls-files -co --exclude-standard -- . )
else
  FILES=$(find . -type f \( -path ./Fixtures/local -o -path ./Contract/src-v1 -o -name DerivedData -o -name .build \
    -o -name .swiftpm -o -name xcuserdata \) -prune -o -type f -print | sed 's|^\./||' | grep -v '/\(Fixtures/local\|Contract/src-v1\|\.build\|\.swiftpm\|DerivedData\|xcuserdata\)/' || true)
fi
LIST=$(mktemp "${TMPDIR:-/tmp}/ft-privacy.XXXXXX")
trap 'rm -f "$LIST"' EXIT
print -r -- "$FILES" > "$LIST"
python3 - "$FT_IOS" "$LIST" "${EXTRA[@]}" <<'PY'
import os, re, sys
root, extra = sys.argv[1], sys.argv[3:]
files = [l for l in open(sys.argv[2]).read().splitlines() if l.strip()]
problems = []

# 1. paths
bad_ext = ('.qmdl', '.qmdl2', '.bin', '.stub', '.tar.gz', '.tgz', '.pcap', '.pcapng', '.xcresult', '.sysdiagnose')
for f in files:
    if f.startswith('Fixtures/local/') or f == 'Fixtures/local':
        problems.append(f'{f}: capture-derived fixture would be committed')
    elif f.lower().endswith(bad_ext) or '.xcresult/' in f:
        problems.append(f'{f}: capture or binary trace file would be committed')

# 2. identifier shapes
DIGITS = re.compile(r'[0-9]{10,}')
HEXTOKEN = re.compile(r'[0-9A-Fa-f]+')
IPV4 = re.compile(r'(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])')
IPV6 = re.compile(r'\b(?:[0-9A-Fa-f]{1,4}:){5,7}[0-9A-Fa-f]{1,4}\b|\b[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){1,6}::(?:[0-9A-Fa-f]{1,4}\b)?')
HEX = re.compile(r'0[xX][0-9A-Fa-f]{8,}')
ALLOWED_DIGITS = {'4294967295', '2147483647'}
ALLOWED_HEX = {'0xffffffff'}

def mask(s):
    return s[:2] + '…' + f'({len(s)} chars)'

def scan(path, label):
    try:
        data = open(path, 'rb').read()
    except OSError:
        return
    if b'\0' in data[:8192]:
        return                                           # binary (PNG, asset catalog)
    text = data.decode('utf-8', 'replace')
    for n, line in enumerate(text.splitlines(), 1):
        for m in DIGITS.finditer(line):
            if m.group() in ALLOWED_DIGITS:
                continue
            tok = next((t for t in HEXTOKEN.finditer(line) if t.start() <= m.start() and m.end() <= t.end()), None)
            if tok and len(tok.group()) in (32, 40, 64):
                continue                                 # an md5/sha digest, not an identifier
            problems.append(f'{label}:{n}: {len(m.group())}-digit run {mask(m.group())}')
        for m in IPV4.finditer(line):
            if all(len(o) == 1 for o in m.group().split('.')):
                continue                                 # a 3GPP clause or version ("table 5.4.2.1-1")
            problems.append(f'{label}:{n}: IPv4-shaped {mask(m.group())}')
        for m in IPV6.finditer(line):
            problems.append(f'{label}:{n}: IPv6-shaped {mask(m.group())}')
        for m in HEX.finditer(line):
            if m.group().lower().rstrip('l') in ALLOWED_HEX:
                continue
            if line[m.end():m.end() + 4] == '.bin' and len(m.group()) == 10:
                continue                                 # a QDSS chunk file name, 0x0000006F.bin
            problems.append(f'{label}:{n}: 0x-hex of {len(m.group()) - 2} digits {mask(m.group())}')

for f in files:
    scan(os.path.join(root, f), f)
for e in extra:
    if os.path.isdir(e):
        for d, _, names in os.walk(e):
            for name in names:
                scan(os.path.join(d, name), os.path.join(d, name))
    else:
        scan(e, e)

# 3. networking
NET = re.compile(r'\bURLSession\b|\bNWConnection\b|\bNWPathMonitor\b|^\s*import\s+Network\b|\bNSURLConnection\b|'
                 r'\bCFSocket|\bCFStream|^\s*import\s+WebKit\b|\bWKWebView\b|\bSFSafariViewController\b|'
                 r'^\s*import\s+SafariServices\b')
for f in files:
    if not (f.startswith('App/') or f.startswith('FieldTapKit/Sources/')) or not f.endswith('.swift'):
        continue
    for n, line in enumerate(open(os.path.join(root, f), encoding='utf-8', errors='replace'), 1):
        if NET.search(line):
            problems.append(f'{f}:{n}: networking or in-app browser API: {line.strip()[:80]}')

for p in problems:
    print(p)
print(f'privacy-gate: {len(files)} files checked{", plus " + str(len(extra)) + " scanned paths" if extra else ""}, '
      f'{len(problems)} problems')
sys.exit(1 if problems else 0)
PY
