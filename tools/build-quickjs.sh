#!/bin/sh

# Build the tiny QuickJS ABI used by the KOReader plugin.  The source archive
# is downloaded outside the repository and is removed with the temporary build
# directory when this script exits; only the requested shared object remains.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TARGET=${1:-host}
QUICKJS_VERSION=${QUICKJS_VERSION:-2025-04-26}
QUICKJS_URL=${QUICKJS_URL:-https://bellard.org/quickjs/quickjs-${QUICKJS_VERSION}.tar.xz}
QUICKJS_SOURCE_DIR=${QUICKJS_SOURCE_DIR:-}

case "$TARGET" in
    host)
        TARGET_ARCH=${TARGET_ARCH:-x86_64}
        TARGET_CC=${TARGET_CC:-cc}
        TARGET_CFLAGS=${TARGET_CFLAGS:-}
        TARGET_DEFINES=${TARGET_DEFINES:-}
        TARGET_LDFLAGS=${TARGET_LDFLAGS:-}
        ;;
    armel)
        TARGET_ARCH=${TARGET_ARCH:-armel}
        TARGET_CC=${TARGET_CC:-arm-linux-gnueabi-gcc}
        TARGET_CFLAGS=${TARGET_CFLAGS:--O2 -march=armv7-a}
        TARGET_DEFINES=${TARGET_DEFINES:--DLEGADO_LEGACY_TIME32 -D_TIME_BITS=32 -D_FILE_OFFSET_BITS=32 -Dclock_gettime=legado_clock_gettime}
        TARGET_LDFLAGS=${TARGET_LDFLAGS:--Wl,-Bstatic -lm -Wl,-Bdynamic -ldl -lpthread}
        ;;
    armhf)
        TARGET_ARCH=${TARGET_ARCH:-armhf}
        TARGET_CC=${TARGET_CC:-arm-linux-gnueabihf-gcc}
        TARGET_CFLAGS=${TARGET_CFLAGS:--O2 -march=armv7-a -mfloat-abi=hard -mfpu=vfpv3-d16}
        # Kindle's 32-bit glibc predates the time64 ABI used by current
        # Debian/Ubuntu ARM headers.  Keep the hard-float build on the
        # firmware-compatible time32 entry points as well.
        TARGET_DEFINES=${TARGET_DEFINES:--DLEGADO_LEGACY_TIME32 -D_TIME_BITS=32 -D_FILE_OFFSET_BITS=32 -Dclock_gettime=legado_clock_gettime}
        TARGET_LDFLAGS=${TARGET_LDFLAGS:--Wl,-Bstatic -lm -Wl,-Bdynamic -ldl -lpthread}
        ;;
    *)
        echo "usage: $0 [host|armel|armhf]" >&2
        exit 2
        ;;
esac

OUTPUT=${OUT:-$ROOT_DIR/plugin/legado.koplugin/lib/$TARGET_ARCH/liblegado_js.so}
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/legado-quickjs.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

if [ -n "$QUICKJS_SOURCE_DIR" ]; then
    QJS_DIR=$QUICKJS_SOURCE_DIR
else
    ARCHIVE="$BUILD_DIR/quickjs.tar.xz"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 "$QUICKJS_URL" -o "$ARCHIVE"
    else
        wget -q "$QUICKJS_URL" -O "$ARCHIVE"
    fi
    tar -xJf "$ARCHIVE" -C "$BUILD_DIR"
    QJS_DIR="$BUILD_DIR/quickjs-$QUICKJS_VERSION"
fi

mkdir -p "$(dirname -- "$OUTPUT")"

# TARGET_CFLAGS is intentionally a shell word list so callers can pass target
# tuning flags without modifying this script (for example a Kindle vendor
# toolchain with its own sysroot options).
"$TARGET_CC" $TARGET_CFLAGS $TARGET_DEFINES -fPIC -I"$QJS_DIR" \
    -DCONFIG_VERSION=\"$QUICKJS_VERSION\" -shared -Wl,-soname,liblegado_js.so \
    "$ROOT_DIR/native/legado_js.c" \
    "$QJS_DIR/quickjs.c" "$QJS_DIR/libregexp.c" "$QJS_DIR/libunicode.c" \
    "$QJS_DIR/cutils.c" "$QJS_DIR/dtoa.c" \
    $TARGET_LDFLAGS -s -o "$OUTPUT"

echo "built $OUTPUT"
