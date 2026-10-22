#!/bin/sh
# Tiêm LocketPlus.dylib vào IPA Locket.
#
# Dùng:
#   ./tools/inject.sh <input.ipa> <output.ipa> [LocketPlus.dylib]
#
# Không cần optool/insert_dylib: dùng tools/insert_dylib.py (ghi vào vùng đệm
# của header, KHÔNG dịch chuyển byte nào).
set -e

IN="$1"
OUT="${2:-LocketPlus-injected.ipa}"
DY="${3:-LocketPlus.dylib}"
HERE=$(cd "$(dirname "$0")" && pwd)

[ -f "$IN" ] || { echo "không thấy IPA: $IN"; exit 1; }
[ -f "$DY" ] || { echo "không thấy dylib: $DY"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> giải nén"
unzip -q "$IN" -d "$WORK"

APP=$(ls -d "$WORK"/Payload/*.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "không thấy .app trong Payload"; exit 1; }
BIN="$APP/$(basename "$APP" .app)"
[ -f "$BIN" ] || { echo "không thấy binary: $BIN"; exit 1; }
echo "==> app: $(basename "$APP")"

echo "==> copy dylib vào Frameworks/"
mkdir -p "$APP/Frameworks"
cp "$DY" "$APP/Frameworks/LocketPlus.dylib"

echo "==> thêm load command"
python3 "$HERE/insert_dylib.py" "$BIN" "@executable_path/Frameworks/LocketPlus.dylib"

echo "==> ký lại"
if command -v ldid >/dev/null 2>&1; then
    ldid -S "$BIN"
    for f in "$APP"/Frameworks/*.dylib; do ldid -S "$f" 2>/dev/null || true; done
    echo "    đã ký bằng ldid"
else
    echo "    KHÔNG có ldid — hãy ký bằng công cụ sideload của bạn (Sideloadly/Esign)"
fi

echo "==> đóng gói"
rm -f "$OUT"
(cd "$WORK" && zip -qry "$OLDPWD/$OUT" Payload)
ls -lh "$OUT"
echo "xong: $OUT"
