#!/bin/sh
# NOTE: written by an AI agent for AI agents; check it against the current
# sources before relying on it.
# Run a command on an Intel GPU stack installed in a private prefix.
#   run-on-stack.sh full <prefix> <cache-dir> <command> [args...]
#   run-on-stack.sh igc  <prefix> <cache-dir> <command> [args...]
#   run-on-stack.sh neo  <prefix> <cache-dir> <command> [args...]
# full: the prefix's loader, compute-runtime, IGC, gmmlib and ocloc.
# igc:  the system's loader, compute-runtime and ocloc with the prefix's IGC.
# neo:  the prefix's loader, compute-runtime, gmmlib and ocloc with the
#       system's IGC.
# <cache-dir> becomes NEO_CACHE_DIR: give each stack and each mix its own.
# For igc and neo, links to the libraries taken from the prefix go in
# <cache-dir>.libs (a directory beside the cache).
set -eu
[ $# -ge 4 ] || {
  echo "usage: $0 full|igc|neo <prefix> <cache-dir> <command> [args...]" >&2
  exit 2
}
kind=$1 prefix=$2 cache=$3
shift 3
driver=$prefix/lib/libze_intel_gpu.so.1
mkdir -p "$cache"
export NEO_CACHE_DIR="$cache"

case $kind in
  full)
    for f in "$driver" "$prefix/lib/libze_loader.so.1" "$prefix/lib/libigc.so.2"; do
      [ -e "$f" ] || { echo "$0: $f is missing" >&2; exit 2; }
    done
    export LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export ZE_ENABLE_ALT_DRIVERS="$driver"
    export PATH="$prefix/bin:$PATH"
    if [ -d "$prefix/etc/OpenCL/vendors" ]; then
      export OCL_ICD_VENDORS="$prefix/etc/OpenCL/vendors"
    fi
    ;;
  igc | neo)
    libs=$cache.libs
    rm -rf "$libs"
    mkdir -p "$libs"
    if [ "$kind" = igc ]; then
      names="libigc.so.2 libigdfcl.so.2 libiga64.so.2 libopencl-clang.so.*"
    else
      [ -e "$driver" ] || { echo "$0: $driver is missing" >&2; exit 2; }
      names="libze_loader.so.1 libze_intel_gpu.so.1 libigdgmm.so.12 libocloc.so
        libze_tracing_layer.so.1 libze_validation_layer.so.1"
    fi
    for n in $names; do
      for f in "$prefix"/lib/$n; do
        [ -e "$f" ] && ln -sf "$f" "$libs/"
      done
    done
    [ "$kind" = igc ] && [ ! -e "$libs/libigc.so.2" ] &&
      { echo "$0: no libigc.so.2 in $prefix/lib" >&2; exit 2; }
    export LD_LIBRARY_PATH="$libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [ "$kind" = neo ]; then
      export ZE_ENABLE_ALT_DRIVERS="$driver"
      export PATH="$prefix/bin:$PATH"
    fi
    ;;
  *)
    echo "$0: unknown kind $kind (full, igc or neo)" >&2
    exit 2
    ;;
esac
exec "$@"
