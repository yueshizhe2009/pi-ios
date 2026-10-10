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
# The upstream JSCOnly target compiles this Objective-C++ file without ARC,
# but OSLogPrintStream.mm explicitly requires ARC. Enable ARC for this file only.
arc_patch = """
# iOS JSC-only build: OSLogPrintStream.mm uses Objective-C ARC.
set_source_files_properties(
    "${CMAKE_SOURCE_DIR}/Source/WTF/wtf/darwin/OSLogPrintStream.mm"
    PROPERTIES COMPILE_FLAGS "-fobjc-arc"
)
"""
if "OSLogPrintStream.mm" not in s or "-fobjc-arc" not in s:
    s = s.rstrip() + "\n" + arc_patch

p.write_text(s)

# Current WebKit main has a macOS-specific memoryFootprint(task) call in this
# source while the iOS/JSCOnly configuration exposes only memoryFootprint().
# Memory pressure monitoring is not needed for this standalone JSC build; make
# the Cocoa implementation return 0 for this metric to keep the iOS target buildable.
footprint = Path("Source/WTF/wtf/cocoa/MemoryFootprintCocoa.cpp")
fs = footprint.read_text()
old_call = "    return memoryFootprint(mach_task_self());"
new_call = "    return 0; // Not used by the standalone iOS JSC-only build.\n"
if old_call in fs:
    fs = fs.replace(old_call, new_call, 1)
    footprint.write_text(fs)
elif "return 0; // Not used by the standalone iOS JSC-only build." not in fs:
    raise SystemExit("Expected iOS-incompatible memoryFootprint call was not found; refusing to patch unexpected source.")

print("Patched JSCOnly CMake and iOS-specific WebKit source compatibility.")
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
    -DENABLE_REMOTE_INSPECTOR=OFF

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
# WebKit's JSCOnly CMake build does not generate the Xcode-style Headers directory.
# Export the public JavaScriptCore C API headers directly from the source tree.
cp "$DEPS_DIR/WebKit/Source/JavaScriptCore/API/"*.h build/ios-webkit-device/include/
cp "$DEPS_DIR/WebKit/build-ios-device/cmakeconfig.h" build/ios-webkit-device/include/

# The ios-port branch currently provides only an iOS Simulator toolchain.
# Generate the matching device toolchain expected by this build script.
cat > "$DEPS_DIR/bun/cmake/toolchains/ios-device.cmake" <<'CMAKE'
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT iphoneos)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 16.0)
set(CMAKE_C_COMPILER_TARGET arm64-apple-ios16.0)
set(CMAKE_CXX_COMPILER_TARGET arm64-apple-ios16.0)
execute_process(
    COMMAND xcrun --sdk iphoneos --show-sdk-path
    OUTPUT_VARIABLE IOS_SDK_PATH
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
set(ENV{IOS_SYSROOT} "${IOS_SDK_PATH}")
CMAKE

# Bun 的 CMake configure 会 file(STRINGS) 读取 cmake/sources/*.txt，而这些清单
# 是由 cmake/Sources.json 经 scripts/glob-sources.mjs 生成的（正常由 scripts/build.mjs
# 调用）。ios-port 分支没有把它们提交进仓库，且 glob 是相对进程 CWD 扫描的 ——
# 所以必须在这里、以 Bun 仓库根为 CWD 用 bun 跑一次。
bun scripts/glob-sources.mjs

mkdir -p build/ios-device && cd build/ios-device

cmake ../.. \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=../../cmake/toolchains/ios-device.cmake

# Bun 默认下载预编译 WebKit（WEBKIT_LOCAL 未开），其 FastJITPermissions.h 在
# ARM64+Darwin 上无条件走 pthread 分支（该分支在 oven-sh/WebKit 里写作
# `#elif CPU(ARM64)`，没有上游那样的 USE() 守卫），于是 iOS 真机调用
# pthread_jit_write_protect_supported_np() / pthread_jit_write_protect_np()，
# 而 iPhoneOS SDK 把这两个符号标记为 unavailable：
#   FastJITPermissions.h:105:18: error: 'pthread_jit_write_protect_supported_np' is unavailable
# 本构建 ENABLE_JIT=OFF，改为在 iOS 上落回 WebKit 自带的安全分支
# （threadSelfRestrictSupported→false；restrict 只在 supported 为真时才会被调用）。
WEBKIT_HDR=$(find "$PWD/cache" -path "*/webkit-*/include/JavaScriptCore/FastJITPermissions.h" 2>/dev/null | head -1)
if [ -n "$WEBKIT_HDR" ]; then
  python3 - "$WEBKIT_HDR" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = "#elif CPU(ARM64)"
new = "#elif CPU(ARM64) && !PLATFORM(IOS_FAMILY)"
if new in s:
    print(f"already patched: {p}")
elif s.count(old) == 1:
    p.write_text(s.replace(old, new, 1))
    print(f"patched: {p}")
else:
    hits = [f"{i}: {l}" for i, l in enumerate(s.splitlines(), 1)
            if "CPU(ARM64)" in l or "JIT_PERMISSIONS" in l]
    raise SystemExit(f"未找到唯一的 '{old}'（命中 {s.count(old)} 次）。候选行:\n" + "\n".join(hits))
PY
else
  echo "警告：没找到 FastJITPermissions.h，跳过 iOS JIT 权限补丁" >&2
fi

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
