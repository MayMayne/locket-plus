#!/bin/sh
# Build LocketPlus.dylib bằng clang của Xcode (không cần theos)
# Dùng trên macOS / GitHub Actions runner.
set -e

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=${1:-build}
MIN=${MIN_IOS:-15.0}

mkdir -p "$OUT"

# Chỉ arm64. Slice arm64e trong một dylib không có chữ ký ad-hoc hợp lệ
# làm dyld từ chối nạp trên máy không jailbreak -> app chết ngay khi mở.
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min="$MIN" \
  -dynamiclib -fobjc-arc -fmodules \
  -O2 -fvisibility=default \
  -Wno-deprecated-declarations \
  -framework Foundation -framework UIKit -framework AVFoundation \
  -framework PhotosUI -framework CoreMedia -framework QuartzCore \
  -install_name @rpath/LocketPlus.dylib \
  Tweak/*.m \
  -o "$OUT/LocketPlus.dylib"

echo "==> $OUT/LocketPlus.dylib"
lipo -info "$OUT/LocketPlus.dylib" || true
codesign -s - -f "$OUT/LocketPlus.dylib" 2>/dev/null || true
codesign -dv "$OUT/LocketPlus.dylib" 2>&1 | head -3 || true
