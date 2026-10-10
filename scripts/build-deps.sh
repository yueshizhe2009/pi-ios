#!/bin/bash
# Build all dependencies for Pi iOS from source

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEPS_DIR="$PROJECT_DIR/deps"
VENDOR_DIR="$PROJECT_DIR/vendor"

mkdir -p "$DEPS_DIR" "$VENDOR_DIR"

echo "Building Pi iOS dependencies..."
echo "==============================="
echo ""
echo "This will:"
echo "  1. Build WebKit/JSC for iOS (C_LOOP interpreter)"
echo "  2. Build Bun for iOS"
echo "  3. Build Ghostty for iOS"
echo ""
echo "Estimated time: ~2 hours"
echo ""

# Build WebKit
echo "[1/3] Building WebKit for iOS..."
cd "$DEPS_DIR"

if [ ! -d "WebKit" ]; then
    git clone --depth 1 https://github.com/WebKit/WebKit.git
fi

cd WebKit

# The upstream JSCOnly CMake file unconditionally generates macOS Mach-exception
# glue on every Apple platform. The iOS SDK does not ship mach/mach_exc.defs,
# and the app disables JIT, so skip that macOS-only generated source on iOS.
python3 - <<'PY'
from pathlib import Path

p = Path("Source/WTF/wtf/PlatformJSCOnly.cmake")
s = p.read_text()

old = """elseif (APPLE)
    file(COPY mac/MachExceptions.defs DESTINATION ${WTF_DERIVED_SOURCES_DIR})
    add_custom_command(
        OUTPUT
            ${WTF_DERIVED_SOURCES_DIR}/MachExceptionsServer.h
            ${WTF_DERIVED_SOURCES_DIR}/mach_exc.h
            ${WTF_DERIVED_SOURCES_DIR}/mach_excServer.c
            ${WTF_DERIVED_SOURCES_DIR}/mach_excUser.c
        MAIN_DEPENDENCY mac/MachExceptions.defs
        WORKING_DIRECTORY ${WTF_DERIVED_SOURCES_DIR}
        COMMAND ${Mig_EXECUTABLE} -header mach_exc.h -user mach_excUser.c
            -sheader MachExceptionsServer.h -server mach_excServer.c
            -DMACH_EXC_SERVER_TASKIDTOKEN_STATE -isysroot ${CMAKE_OSX_SYSROOT}
            MachExceptions.defs
        VERBATIM)
    if (NOT USE_GLIB)
"""
new = """elseif (APPLE)
    if (CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        file(COPY mac/MachExceptions.defs DESTINATION ${WTF_DERIVED_SOURCES_DIR})
        add_custom_command(
            OUTPUT
                ${WTF_DERIVED_SOURCES_DIR}/MachExceptionsServer.h
                ${WTF_DERIVED_SOURCES_DIR}/mach_exc.h
                ${WTF_DERIVED_SOURCES_DIR}/mach_excServer.c
                ${WTF_DERIVED_SOURCES_DIR}/mach_excUser.c
            MAIN_DEPENDENCY mac/MachExceptions.defs
            WORKING_DIRECTORY ${WTF_DERIVED_SOURCES_DIR}
            COMMAND ${Mig_EXECUTABLE} -header mach_exc.h -user mach_excUser.c
                -sheader MachExceptionsServer.h -server mach_excServer.c
                -DMACH_EXC_SERVER_TASKIDTOKEN_STATE -isysroot ${CMAKE_OSX_SYSROOT}
                MachExceptions.defs
            VERBATIM)
    endif ()
    if (NOT USE_GLIB)
"""
if old not in s:
    raise SystemExit("Expected Mach-exception CMake block was not found; refusing to patch unexpected source.")
s = s.replace(old, new, 1)

old_sources = """        generic/MemoryPressureHandlerGeneric.cpp

        ${WTF_DERIVED_SOURCES_DIR}/mach_excServer.c
        ${WTF_DERIVED_SOURCES_DIR}/mach_excUser.c
    )
"""
new_sources = """        generic/MemoryPressureHandlerGeneric.cpp
    )
    if (CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        list(APPEND WTF_SOURCES
            ${WTF_DERIVED_SOURCES_DIR}/mach_excServer.c
            ${WTF_DERIVED_SOURCES_DIR}/mach_excUser.c
        )
    endif ()
"""
if old_sources not in s:
    raise SystemExit("Expected Mach-exception source list was not found; refusing to patch unexpected source.")
s = s.replace(old_sources, new_sources, 1)
p.write_text(s)
print("Patched JSCOnly CMake to skip macOS-only Mach exception glue for iOS.")
PY

rm -rf build-ios-device
mkdir build-ios-device && cd build-ios-device

cmake .. \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DPORT=JSCOnly \
    -DENABLE_STATIC_JSC=ON \
    -DUSE_THIN_ARCHIVES=OFF \
    -DENABLE_JIT=OFF \
    -DENABLE_FTL_JIT=OFF \
    -DENABLE_DFG_JIT=OFF \
    -DENABLE_C_LOOP=ON \
    -DENABLE_SAMPLING_PROFILER=OFF \
    -DENABLE_WEBASSEMBLY=OFF \
    -DENABLE_REMOTE_INSPECTOR=ON

ninja JavaScriptCore

echo "WebKit built successfully!"

# Build Bun
echo ""
echo "[2/3] Building Bun for iOS..."
cd "$DEPS_DIR"

if [ ! -d "bun" ]; then
    git clone https://github.com/dannote/bun.git -b ios-port
fi

cd bun

# Copy WebKit libs
mkdir -p build/ios-webkit-device/lib build/ios-webkit-device/include
cp "$DEPS_DIR/WebKit/build-ios-device/lib/"*.a build/ios-webkit-device/lib/
cp -r "$DEPS_DIR/WebKit/build-ios-device/JavaScriptCore/Headers/"* build/ios-webkit-device/include/
cp "$DEPS_DIR/WebKit/build-ios-device/cmakeconfig.h" build/ios-webkit-device/include/

mkdir -p build/ios-device && cd build/ios-device

cmake ../.. \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=../../cmake/toolchains/ios-device.cmake

ninja

echo "Bun built successfully!"

# Package Bun libs
mkdir -p "$VENDOR_DIR/bun-device/lib" "$VENDOR_DIR/bun-device/include"

BUN_OBJECTS=$(find CMakeFiles/bun-profile.dir -name "*.o" -type f | sort)
ar rcs "$VENDOR_DIR/bun-device/lib/libbun.a" $BUN_OBJECTS bun-zig.o

cp ../ios-webkit-device/lib/*.a "$VENDOR_DIR/bun-device/lib/"
cp mimalloc/CMakeFiles/mimalloc-obj.dir/src/static.c.o "$VENDOR_DIR/bun-device/lib/mimalloc.o"
cp -r ../ios-webkit-device/include/* "$VENDOR_DIR/bun-device/include/"

# Copy other libs
for lib in boringssl/libcrypto.a boringssl/libssl.a boringssl/libdecrepit.a \
           brotli/libbrotlicommon.a brotli/libbrotlidec.a brotli/libbrotlienc.a \
           cares/lib/libcares.a highway/libhwy.a libdeflate/libdeflate.a \
           "lolhtml/aarch64-apple-ios/release/liblolhtml.a" lshpack/libls-hpack.a \
           zlib/libz.a libarchive/libarchive/libarchive.a \
           hdrhistogram/src/libhdr_histogram_static.a zstd/lib/libzstd.a; do
    if [ -f "$lib" ]; then
        cp "$lib" "$VENDOR_DIR/bun-device/lib/"
    fi
done

echo "Bun packaged successfully!"

# Build Ghostty
echo ""
echo "[3/3] Building Ghostty for iOS..."
cd "$DEPS_DIR"

if [ ! -d "ghostty" ]; then
    git clone https://github.com/dannote/ghostty.git -b ios-manual-backend
fi

cd ghostty

zig build \
    -Doptimize=ReleaseFast \
    -Dtarget=aarch64-ios \
    --build-file src/build.zig

mkdir -p "$VENDOR_DIR/ghostty/GhosttyKit.xcframework/ios-arm64"
cp zig-out/lib/libghostty.a "$VENDOR_DIR/ghostty/GhosttyKit.xcframework/ios-arm64/libghostty-fat.a"
cp -r zig-out/include "$VENDOR_DIR/ghostty/GhosttyKit.xcframework/ios-arm64/Headers"

echo "Ghostty built successfully!"

echo ""
echo "==============================="
echo "All dependencies built!"
echo "Vendor libraries are in: $VENDOR_DIR"
