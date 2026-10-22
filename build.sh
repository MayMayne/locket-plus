#!/bin/sh
# Build LocketPlus.dylib bằng clang của Xcode (không cần theos).
set -e

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=${1:-build}
MIN=${MIN_IOS:-15.0}

mkdir -p "$OUT"

# Chỉ arm64. Slice arm64e trong dylib không ký ad-hoc hợp lệ sẽ bị dyld từ chối.
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min="$MIN" \
  -dynamiclib -fobjc-arc -fmodules -fblocks \
  -O2 -fvisibility=default \
  -Wno-deprecated-declarations \
  -Wno-unused-function -Wno-unused-variable \
  -framework Foundation -framework UIKit -framework AVFoundation \
  -framework AVFAudio -framework CoreMedia -framework QuartzCore \
  -framework Security -framework CoreFoundation -ldl \
  -install_name @rpath/LocketPlus.dylib \
  Tweak/*.m \
  -o "$OUT/LocketPlus.dylib"

echo "==> $OUT/LocketPlus.dylib"
lipo -info "$OUT/LocketPlus.dylib" || true
codesign -s - -f "$OUT/LocketPlus.dylib" 2>/dev/null || true
codesign -dv "$OUT/LocketPlus.dylib" 2>&1 | head -3 || true
