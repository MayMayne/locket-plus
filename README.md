# LocketPlus (`LocketPlus.dylib`) v2.0

Một dylib duy nhất cho **Locket 2.68+**, viết lại từ đầu sau khi disassemble 3 dylib mẫu
(`blatantsPatch`, `AutoRcSideload`, `MHVideoPipeline`).

## Ba việc nó làm

| Việc | Cách làm | Có thật sự được không |
|---|---|---|
| **Sống sót sideload** (không màn đen, không hỏng đăng nhập) | Canary keychain → đọc access group THẬT → fishhook `SecItem*` để THAY group (không xoá) + swizzle `containerURLForSecurityApplicationGroupIdentifier:` | ✅ Chắc chắn — đây đúng là cách `blatantsPatch` làm |
| **Quay 10 phút / 500MB** | `AVCaptureMovieFileOutput.setMaxRecordedDuration/FileSize` → 600s / 500MB; `AVAssetExportSession.setFileLengthLimit` → 500MB; `setCanPerformMultiplePassesOverSourceMediaData` → YES; preset ladder HighestQuality→1920x1080→1280x720→Medium | ✅ Phía client. Upload vẫn phải qua Storage rules của Locket |
| **Mở khoá Gold** | Rewrite JSON response của `api.revenuecat.com/v1/subscribers/*` (thêm entitlement + subscription còn hạn) → SDK tự parse ra CustomerInfo có Gold; + nhân bản entitlement key; + `activeSubscriptions` | ⚠️ **Client-side.** UI/gate của app mở. Badge trên máy người khác KHÔNG hiện (server không biết) |
| **Kết bạn** | Chẩn đoán: bắt request `sendFriendRequest`/`acceptFriendRequest`, log HTTP status + body; 401 → refresh ID token + App Check rồi replay 1 lần; mở hạn mức bạn bè qua Remote Config | ⚠️ 401 cứu được. **403 (App Check) thì không** — xem dưới |

## Sự thật về kết bạn (đã kiểm chứng nhiều lần)

`sendFriendRequest` / `acceptFriendRequest` là Cloud Functions (project `locket-4252a`).
Server kiểm `X-Firebase-AppCheck`. Bản ký lại bằng chứng chỉ khác **không tạo được
attestation hợp lệ** cho team `SWD4AZY4KG`. Refresh token không tạo ra attestation.

- **401** (token cũ/hỏng do keychain đứt khi sideload) → refresh + replay **cứu được**.
- **403** (App Check từ chối) → **không cứu được ở client**.
- **Hạn mức bạn bè** (`max_friends_count`, `friend_limit_mode`...) là gate **client** đọc
  từ Remote Config → dylib mở được. Nếu bạn bị chặn vì "You already have N friends"
  thì sẽ hết chặn.

Đường còn lại cho 403: cài bằng **TrollStore / jailbreak giữ chữ ký gốc**, hoặc để người
dùng bản App Store gốc bấm accept link mời.

## Cấu hình

`Documents/LocketPlus/config.plist` (tự tạo lần đầu chạy):

| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `maxVideoSeconds` | 600 | Trần thời lượng quay |
| `maxVideoBytes` | 524288000 | Trần dung lượng (500MB) |
| `goldUnlock` | true | Bật/tắt mở Gold |
| `friendLimitUnlock` | true | Mở hạn mức bạn bè (Remote Config) |
| `friendDiagnostics` | true | Ghi `friend.log` |
| `autoRefreshOnAuthFail` | true | 401 → refresh + replay |
| `keepMicOnRecord` | true | Giữ audio session để video có tiếng |
| `addMicInput` | true | Thêm micro vào AVCaptureSession nếu thiếu |
| `expandExportRange` | **false** | Nới `AVAssetExportSession.timeRange` (phá trim của user — chỉ bật nếu biết mình làm gì) |
| `safeMode` | false | Tắt toàn bộ hook (cứu hộ) |

## Chẩn đoán

`Documents/LocketPlus/`:
- `log.txt` — log chung (tự xoá khi > 512KB)
- `friend.log` — kết quả chẩn đoán kết bạn
- `boot.trace` — các bước boot (nếu app chết giữa chừng, đọc file này)
- `crash.txt` — crash gần nhất + bước cuối
- `crash.count` — số lần chết liên tiếp; >= 2 → tự bật `safeMode`

## Build

GitHub Actions (`.github/workflows/build-dylib.yml`) — mỗi push lên `main` build và
release `LocketPlus.dylib` arm64 đã ký ad-hoc.

Hoặc trên máy Mac có Xcode: `./build.sh` → `build/LocketPlus.dylib`.

## Nhúng vào IPA

```sh
cp LocketPlus.dylib Payload/Locket.app/Frameworks/
python3 tools/inject.py Payload/Locket.app LocketPlus.dylib   # cần: pip install lief
# hoặc: optool install -c load -p "@executable_path/Frameworks/LocketPlus.dylib" -t Payload/Locket.app/Locket
```

Xoá `blatantsPatch.dylib`, `AutoRcSideload.dylib` cũ nếu có — chúng hook trùng.

## Những gì đã bị bỏ so với v1.x (và vì sao)

| Bỏ | Lý do |
|---|---|
| `LPProfile.m` (Profile+ UI) | Dựng lại cây view profile của app → `unrecognized selector` khi Locket đổi layout. Đây là nguồn crash lớn nhất |
| `LPNotes.m` (ghi chú genz) | 456 dòng UI, không liên quan 3 mục tiêu |
| `LPExplorer.m` / `LPPatch.m` | Hook class theo tên đoán → im lặng hoặc crash |
| `LPExport.m` | Trùng hook với `LPMedia` → đệ quy |
| Hook `RCEntitlementInfos.all/.active` trả NSDictionary | Value thật là **object** `RCEntitlementInfo`, không phải dict → `unrecognized selector` → crash ngay khi mở app (lỗi v1.4–v1.11) |
| `MSHookFunction` cho `SecItem*` | Vá mã máy trong dyld shared cache → iOS 15+ giết process trong constructor (lỗi v1.12) |
| `CFDictionaryRemoveValue(query, kSecAttrAccessGroup)` | Xoá group → Firebase Auth mất phiên → màn đen + quay mãi ở login (lỗi v1.12/v1.13) |
| Hook `-[AVAsset duration]`, `-[NSFileManager attributesOfItemAtPath:]` | Getter trả struct / chạy hàng nghìn lần → crash hoặc làm hỏng đọc file |
