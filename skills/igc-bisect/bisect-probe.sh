#!/bin/sh
# NOTE: written by an AI agent for AI agents; check it against the current
# sources before relying on it.
# A `git bisect run` script that builds each IGC commit once, runs every test
# case on it once, and caches the result, so several bisects share builds.
#   cd <igc-src>   # the checkout BUILD_CMD builds
#   OUT=<dir> BUILD_CMD=<cmd> PROBE_CMD=<cmd> git bisect run sh <path>/bisect-probe.sh <case>
#   sh bisect-probe.sh --probe-only      # fill the cache for HEAD, no verdict
# BUILD_CMD   run as `$BUILD_CMD <commit>`; exit 0 when the build is installed
#             (for example: sh <path>/build-igc.sh)
# PROBE_CMD   run as `$PROBE_CMD <probe-dir>` with the new IGC in place; it
#             prints the name of every FAILING case, one per line, on stdout,
#             and exits 0 when it got results (non-zero: no result, skipped)
# MODE        regression (default): exit 0 (good) when <case> passes, 1 (bad)
#             when it fails. fix: exit 0 (old) when <case> fails, 1 (new) when
#             it passes; start git bisect with --term-old=broken --term-new=fixed.
# OUT/cache.tsv holds one line per commit: commit, status (ok, buildfail,
# noresult) and the failing cases joined by ';' (the commit's signature).
# Exit 125 (skip) when the commit did not build or gave no result.
set -u
out=${OUT:?OUT}
mkdir -p "$out/builds" "$out/probes"
touch "$out/cache.tsv"
c=$(git rev-parse HEAD)
line=$(grep "^$c	" "$out/cache.tsv" | tail -1)
if [ -z "$line" ]; then
  if $BUILD_CMD "$c" >"$out/builds/$c.log" 2>&1; then
    rm -rf "$out/probes/$c"
    mkdir -p "$out/probes/$c"
    if fails=$($PROBE_CMD "$out/probes/$c" 2>"$out/probes/$c/stderr.log"); then
      line="$c	ok	$(printf '%s\n' "$fails" | grep . | sort | paste -sd';')"
    else
      line="$c	noresult	"
    fi
  else
    line="$c	buildfail	"
  fi
  # The build may have edited the checkout; leave it as git bisect expects.
  git checkout -q -f "$c"
  printf '%s\n' "$line" >>"$out/cache.tsv"
fi
[ "${1:-}" = --probe-only ] && { echo "$line"; exit 0; }
case=${1:?usage: bisect-probe.sh <case> | --probe-only}
st=$(printf '%s' "$line" | cut -f2)
fails=$(printf '%s' "$line" | cut -f3)
if [ "$st" != ok ]; then
  v=skip rc=125
else
  case ";$fails;" in
    *";$case;"*) failing=1 ;;
    *) failing=0 ;;
  esac
  if [ "${MODE:-regression}" = fix ]; then rc=$((1 - failing)); else rc=$failing; fi
  [ "$failing" = 1 ] && v=failing || v=passing
fi
echo "$(date -Is) $c $v [$case] signature: $fails" >>"$out/verdicts.log"
exit "$rc"
