#!/bin/sh
# NOTE: written by an AI agent for AI agents; check it against the current
# sources before relying on it.
# Build and install IGC at one commit, release mode, incrementally in one
# build tree, with IGC's dependencies held fixed.
#   build-igc.sh <commit> [patch...]        exit 0 built and installed, 1 failed
# Environment (all required except JOBS, LLVM_VERSION, CMAKE_EXTRA):
#   WS        IGC workspace: WS/igc (the bisect checkout), WS/vc-intrinsics,
#             WS/SPIRV-Tools, WS/SPIRV-Headers, WS/llvm-project with
#             llvm/projects/opencl-clang and llvm/projects/llvm-spirv
#   BUILD     the IGC build tree (reused from commit to commit)
#   PREFIX    where libigc.so.2 & co. are installed (replaced each time)
#   LLVM_VERSION  e.g. 22.1.8 (default: WS/llvm-project's llvmorg- tag)
#   JOBS      parallel jobs (default 10)
#   CMAKE_EXTRA   more cmake options
# WS/igc is reset with `git checkout -f` and `git clean -fdq`: use a checkout
# that holds nothing else.
set -u
c=${1:?usage: build-igc.sh <commit> [patch...]}
shift
ws=${WS:?WS} b=${BUILD:?BUILD} p=${PREFIX:?PREFIX}
jobs=${JOBS:-10}
llvm=${LLVM_VERSION:-$(git -C "$ws/llvm-project" describe --tags --exact-match 2>/dev/null | sed 's/^llvmorg-//')}
[ -n "$llvm" ] || { echo "set LLVM_VERSION"; exit 1; }
t0=$(date +%s)
end() { echo "BUILD-END $c status=$1 seconds=$(($(date +%s) - t0))"; exit "$1"; }

git -C "$ws/igc" checkout -q -f --detach "$c" || end 1
git -C "$ws/igc" clean -fdq
for patch in "$@"; do
  git -C "$ws/igc" apply "$patch" || { echo "patch $patch failed"; end 1; }
done
echo "igc $(git -C "$ws/igc" log -1 --format='%H %cs %s')"

cm=$ws/igc/IGC/CMakeLists.txt
# IGC adds -Werror with no option to turn it off.
sed -i 's/ALIAS TreatWarnAsErrorEnabled    "-Werror"/ALIAS TreatWarnAsErrorEnabled/' "$cm"
# From some commits on, IGC adds its build's AdaptorCommon directory to every
# target's include path, LLVM's included, so crossing such a commit rebuilds
# all of LLVM. Generate DriverBuildId.h next to its user instead. Both
# expressions change nothing where the lines do not exist; check them
# against IGC/CMakeLists.txt at your commits.
# shellcheck disable=SC2016 # the ${...} are CMake's, not the shell's.
sed -i -e 's|configure_file(AdaptorCommon/DriverBuildId.h.in "${IGC_BUILD__IGC_BIN_DIR}/AdaptorCommon/DriverBuildId.h")|configure_file(AdaptorCommon/DriverBuildId.h.in "${CMAKE_CURRENT_SOURCE_DIR}/AdaptorCommon/DriverBuildId.h")|' \
  -e '/^include_directories("${IGC_BUILD__IGC_BIN_DIR}\/AdaptorCommon")$/d' "$cm"

# -UCMAKE_CXX_STANDARD: IGC sets C++20 as a normal variable and LLVM caches
# C++17; a reconfigure of an existing tree otherwise builds LLVM as C++20.
# shellcheck disable=SC2086 # CMAKE_EXTRA is a list of words.
CFLAGS=-fno-semantic-interposition CXXFLAGS=-fno-semantic-interposition \
LDFLAGS=-Wl,-Bsymbolic \
nice -n 19 cmake -S "$ws/igc" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$p" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$p" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -UCMAKE_CXX_STANDARD \
  -DIGC_OPTION__LLVM_MODE=Source -DIGC_OPTION__LLVM_PREFERRED_VERSION="$llvm" \
  -DIGC_OPTION__CLANG_MODE=Source -DIGC_OPTION__LLD_MODE=Source \
  -DIGC_OPTION__SPIRV_TOOLS_MODE=Source \
  -DIGC_OPTION__USE_PREINSTALLED_SPIRV_HEADERS=OFF \
  -DIGC_OPTION__VC_INTRINSICS_MODE=Source \
  -DIGC_OPTION__LINK_KHRONOS_SPIRV_TRANSLATOR=ON -DCCLANG_FROM_SYSTEM=OFF \
  ${CMAKE_EXTRA:-} >"$b.configure.log" 2>&1 || { tail -30 "$b.configure.log"; end 1; }

nj() { nice -n 19 ninja -C "$b" -j "$jobs" "$@"; }
# Some commits lack a dependency on a generated header (OCLBiFImpl.h), so an
# incremental build can reach its user first. Build everything else (-k 0)
# and try once more.
if ! nj >"$b.ninja.log" 2>&1 &&
  ! { echo "retrying" >>"$b.ninja.log"; nj -k 0 >>"$b.ninja.log" 2>&1 || nj >>"$b.ninja.log" 2>&1; }; then
  grep -E "error|FAILED" "$b.ninja.log" | head -30
  end 1
fi
rm -rf "${p:?}/lib"
nice -n 19 cmake --install "$b" >"$b.install.log" 2>&1 || end 1
git -C "$ws/igc" rev-parse HEAD >"$p/COMMIT"
end 0
