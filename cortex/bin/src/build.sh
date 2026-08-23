#!/data/data/com.termux/files/usr/bin/bash
# Sweet Dreams - Termux multi-arch build script
# Requirements: pkg install clang binutils ndk-multilib
#
# Produces three binary sets:
#   ../out/arm64/   - aarch64 (modern Android phones, API 21+)
#   ../out/armv7/   - 32-bit ARM (older devices)
#   ../out/x86_64/  - x86_64 (emulators)
#
# Copy all three out/ subdirs into your module's bin/ folder.
# service.sh detects the correct one at runtime via uname -m.

set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$SRC/../out"

TARGETS=(
    "arm64:aarch64-linux-android21"
    "armv7:armv7a-linux-androideabi21"
    "x86_64:x86_64-linux-android21"
)

SOURCES=(
    cpu_apply
    gpu_apply
    perf_apply
    sched_apply
    battery_apply
    thermal_apply
    net_apply
)

# Flags common to all targets
# -O2                  - real speed, no debug bloat
# -fdata-sections
# -ffunction-sections
# -Wl,--gc-sections    - dead code elimination, keeps binaries small
# No -static: Termux Bionic doesn't support static -lc; dynamic linking
# works fine on Android since libc.so is always present on the device.
COMMON_FLAGS="-O2 -fdata-sections -ffunction-sections -Wl,--gc-sections -Wall -Wextra -I$SRC"

compile_target() {
    local arch="$1"
    local triple="$2"
    local outdir="$OUT/$arch"
    mkdir -p "$outdir"

    echo "-- Building for $arch (target: $triple) --"
    local failed=0
    for name in "${SOURCES[@]}"; do
        local src="$SRC/${name}.c"
        local out="$outdir/$name"
        printf "   %-20s" "$name"
        if clang --target="$triple" $COMMON_FLAGS "$src" -o "$out" 2>/tmp/sd_build_err; then
            local kb
            kb=$(du -k "$out" | cut -f1)
            echo "OK  ${kb}K"
        else
            echo "FAILED"
            cat /tmp/sd_build_err | head -5
            failed=1
        fi
    done
    return $failed
}

strip_target() {
    local arch="$1"
    local outdir="$OUT/$arch"
    local stripped=0
    for f in "$outdir"/*; do
        [ -f "$f" ] || continue
        if llvm-strip "$f" 2>/dev/null; then
            stripped=$((stripped + 1))
        fi
    done
    echo "   Stripped $stripped binaries"
}

echo "Sweet Dreams multi-arch build"
echo "Compiler: $(clang --version | head -1)"
echo "Date: $(date)"
echo ""

overall_ok=1

for entry in "${TARGETS[@]}"; do
    arch="${entry%%:*}"
    triple="${entry##*:}"
    if compile_target "$arch" "$triple"; then
        strip_target "$arch"
    else
        overall_ok=0
    fi
    echo ""
done

if [ "$overall_ok" -eq 1 ]; then
    echo "All builds succeeded."
    echo ""
    echo "Binary sizes by arch:"
    for entry in "${TARGETS[@]}"; do
        arch="${entry%%:*}"
        echo "  $arch:"
        du -k "$OUT/$arch"/* | sort -n | awk '{printf "    %-24s %sK\n", $2, $1}' | xargs -I{} echo "  {}"
        du -k "$OUT/$arch"/* | sort -n | while read kb path; do
            printf "    %-24s %sK\n" "$(basename $path)" "$kb"
        done
    done
    echo ""
    echo "Next step: copy the out/ dirs into your module and reflash,"
    echo "or run: cp -r $OUT/* /data/adb/modules/sweet_dreams/bin/"
else
    echo "One or more builds FAILED - check errors above."
    exit 1
fi
