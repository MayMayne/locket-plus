#!/bin/sh
# Build LocketPlus.dylib bằng clang của Xcode (không cần Theos).
set -e

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
OUT=${1:-build}
MIN=${MIN_IOS:-15.0}

mkdir -p "$OUT"

# Chỉ arm64. Slice arm64e trong dylib ký ad-hoc không hợp lệ sẽ bị dyld từ chối
# trên máy thật (con trỏ PAC không được ký lại).
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min="$MIN" \
  -dynamiclib -fobjc-arc -fblocks -fmodules \
  -O2 -fvisibility=default \
  -Wno-deprecated-declarations \
  -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter \
  -Wno-nullability-completeness -Wno-objc-multiple-method-names \
  -framework Foundation -framework UIKit -framework AVFoundation \
  -framework AVFAudio -framework CoreMedia -framework QuartzCore \
  -framework Security -framework CoreFoundation -framework CoreGraphics \
  -install_name @rpath/LocketPlus.dylib \
  Tweak/*.m \
  -o "$OUT/LocketPlus.dylib"

echo "==> $OUT/LocketPlus.dylib"
ls -l "$OUT/LocketPlus.dylib"
lipo -info "$OUT/LocketPlus.dylib" || true
codesign -s - -f "$OUT/LocketPlus.dylib" 2>/dev/null || true
codesign -dv "$OUT/LocketPlus.dylib" 2>&1 | head -3 || true
