#!/bin/zsh
# Regenerates the contract-v1 goldens with FieldTap's Kotlin decoders on the JVM (no Gradle, no network).
# Verified 2026-09-22: baseline sources (foundation src-utc = repo diag + D1 UTC baseline + D2 v30/v26 layouts)
# reproduce ios-foundation/golden/{callflow-golden-utcbaseline,presentation-golden}.json byte for byte; src-v1
# (+ D3 RAT-scoped procedures, + D4 "NR cell pending") changes only the 2 EN-DC reconfigurations and one label.
#
# usage: run-kotlin-golden.sh <src dir> <out dir> <in.qmdl>...
#        run-kotlin-golden.sh --from-repo <out dir> <in.qmdl>...
#
# <src dir> holds CallFlow CellInfo Hdlc LogCodes LteRrc Nas NasFields NasNames NrRrc Protocol (diag),
# CallFlowPresentation (app), Spectrum (core), GoldenDump.kt and PresDump.kt. --from-repo compiles the repo's
# android/diag/src/main/kotlin/com/fieldtap/diag/*.kt (except Gsmtap/LogMask), CallFlowPresentation.kt,
# Spectrum.kt and ios/Contract/tools/*.kt instead: its output equal to the fixtures proves the Android code
# and the contract agree. Each qmdl writes <out dir>/<name>/{callflow-golden,presentation-golden}.json.
set -euo pipefail
HERE=${0:A:h}
REPO=${FT_REPO:-/Users/nikhiljain/Projects/fieldTap}
[[ -d "$REPO/android/diag" ]] || REPO=/Users/nikhiljain/Projects/fieldTap

[[ -n "${FT_TMP:-}" ]] && mkdir -p "$FT_TMP"
WORK=$(mktemp -d "${FT_TMP:-${TMPDIR:-/tmp}}/kotlin-golden.XXXXXX" 2>/dev/null || mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [[ "${1:-}" == "--from-repo" ]]; then
  shift
  SRC="$WORK/src"; mkdir -p "$SRC"
  for f in "$REPO"/android/diag/src/main/kotlin/com/fieldtap/diag/*.kt; do
    case ${f:t} in Gsmtap.kt|LogMask.kt) continue ;; esac
    cp "$f" "$SRC/"
  done
  cp "$REPO"/android/app/src/main/kotlin/com/fieldtap/ui/signalling/CallFlowPresentation.kt "$SRC/"
  cp "$REPO"/android/core/src/main/kotlin/com/fieldtap/core/radio/Spectrum.kt "$SRC/"
  cp "$HERE"/tools/*.kt "$SRC/"
else
  SRC=$1; shift
fi
OUT=$1; shift
(( $# > 0 )) || { echo "usage: $0 <src dir>|--from-repo <out dir> <in.qmdl>..." >&2; exit 2; }

G=~/.gradle/caches/modules-2/files-2.1
j(){ find $G/$1 -name "$2" | head -1; }
STD=$(j org.jetbrains.kotlin/kotlin-stdlib/2.4.20 kotlin-stdlib-2.4.20.jar)
CP=$(j org.jetbrains.kotlin/kotlin-compiler-embeddable/2.4.20 '*.jar'):$STD:$(j org.jetbrains.kotlin/kotlin-script-runtime/2.4.20 '*.jar'):$(j org.jetbrains.kotlin/kotlin-reflect/2.4.0 'kotlin-reflect-2.4.0.jar'):$(j org.jetbrains.kotlin/kotlin-daemon-embeddable/2.4.20 '*.jar'):$(j org.jetbrains.intellij.deps/trove4j '*.jar'):$(j org.jetbrains/annotations/13.0 '*.jar'):$(j org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.9.0 '*.jar')
JAVA=/opt/homebrew/opt/openjdk@21/bin/java
[[ -x $JAVA && -n $STD ]] || { echo "needs Homebrew openjdk@21 and the Gradle-cached Kotlin 2.4.20 jars" >&2; exit 1; }
CLS="$WORK/classes"; mkdir -p "$CLS"
$JAVA -cp "$CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-reflect -no-stdlib -classpath "$STD" -d "$CLS" "$SRC"/*.kt
for Q in "$@"; do
  N=${Q:t:r}; mkdir -p "$OUT/$N"
  $JAVA -cp "$CLS:$STD" com.fieldtap.diag.GoldenDumpKt "$Q" "$OUT/$N"
  $JAVA -cp "$CLS:$STD" com.fieldtap.ui.signalling.PresDumpKt "$Q" "$OUT/$N/presentation-golden.json"
done
