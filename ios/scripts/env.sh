# FieldTap iOS environment. Source it (zsh or bash): `source ios/scripts/env.sh`.
#
# Every path is derived from where this file sits, so a private copy of ios/ (see ios/README.md) runs
# its own tree. FT_REPO is used only to reach the Android/Kotlin and Python sources, which are not
# copied. FT_FIXTURES, FT_SYSDIAGNOSE, FT_SIM_NAME and FT_WP may be set by the caller beforehand.

if [ -n "${BASH_SOURCE:-}" ]; then
  _ft_env_file="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _ft_env_file="${(%):-%x}"
else
  _ft_env_file="$0"
fi
FT_IOS="$(cd "$(dirname "$_ft_env_file")/.." && pwd -P)"
unset _ft_env_file
export FT_IOS

# The canonical tree, where the git-ignored fixtures live and where android/ can be found.
FT_CANONICAL_REPO=/Users/nikhiljain/Projects/fieldTap
if [ -d "$FT_IOS/../android/diag" ]; then
  FT_REPO="$(cd "$FT_IOS/.." && pwd -P)"
else
  FT_REPO="$FT_CANONICAL_REPO"
fi
export FT_REPO FT_CANONICAL_REPO

# Fixtures: this tree's own Fixtures/local (a directory or a symlink), else the canonical one.
if [ -z "${FT_FIXTURES:-}" ]; then
  if [ -e "$FT_IOS/Fixtures/local" ]; then
    FT_FIXTURES="$FT_IOS/Fixtures/local"
  else
    FT_FIXTURES="$FT_CANONICAL_REPO/ios/Fixtures/local"
  fi
fi
export FT_FIXTURES

: "${FT_SYSDIAGNOSE:=$HOME/Downloads/sysdiagnose_2026.09.21_15-41-47-0400_iPhone-OS_iPhone_23F84.tar.gz}"
: "${FT_SIM_NAME:=iPhone 17}"
export FT_SYSDIAGNOSE FT_SIM_NAME

# One build directory per work package; clean.sh deletes it.
FT_TMP="/private/tmp/fieldtap-build/${FT_WP:-local}"
export FT_TMP

# The app's real bundle id (the project's PRODUCT_BUNDLE_IDENTIFIER); the share extension is <id>.share.
export FT_BUNDLE_ID=com.fieldtap.app

# Stop heavy steps below this much free space in the home volume (GB).
export FT_MIN_FREE_GB=3

# Research scratch the fixtures are copied from (it may vanish on reboot; fixtures.sh keeps a copy).
export FT_SCRATCH=/private/tmp/claude-501/-Users-Projects-triptocasino/743a94f1-93ad-4086-b700-6e606c91212e/scratchpad

# Locks shared by every agent on this Mac (macOS has /usr/bin/lockf, not flock).
export FT_BUILD_SLOTS="/private/tmp/fieldtap-build-slot-A.lock /private/tmp/fieldtap-build-slot-B.lock"
export FT_SIM_LOCK=/private/tmp/fieldtap-sim.lock
