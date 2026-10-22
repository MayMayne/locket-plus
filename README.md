# LocketPlus (`LocketPlus.dylib`) v2.0

Một dylib duy nhất cho **Locket 2.68+**, viết lại từ đầu sau khi disassemble 3 dylib mẫu
(`blatantsPatch`, `AutoRcSideload`, `MHVideoPipeline`).

## Ba việc nó làm

| Việc | Cách làm | Có thật sự được không |
|---|---|---|
| **Sống sót sideload** (không màn đen, không hỏng đăng nhập) | Canary keychain → đọc access group THẬT → fishhook `SecItem*` để THAY group (không xoá) + swizzle `containerURLForSecurityApplicationGroupIdentifier:` | ✅ Chắc chắn — đây đúng là cách `blatantsPatch` làm |
| **Quay 10 phút / 500MB** | `AVCaptureMovieFileOutput.setMaxRecordedDuration/FileSize` → 600s / 500MB; `AVAssetExportSession.setFileLengthLimit` → 500MB. Thêm chế độ `compressForUpload` (theo đúng chiến lược `MHVideoPipeline`) để nén vừa giới hạn upload | ✅ Quay/chọn được. Upload vẫn phải qua Storage rules của Locket |
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
| `compressForUpload` | **false** | Theo chiến lược `MHVideoPipeline`: hạ preset + ép `fileLengthLimit` về `uploadTargetBytes` |
| `uploadTargetBytes` | 6291456 (6MB) | Đích dung lượng khi nén |
| `exportMultiPass` | **false** | `setCanPerformMultiplePassesOverSourceMediaData` (mẫu để NO) |
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


## Đính chính: tôi đã đọc sai `MHVideoPipeline` (sửa ngày 22/10)

Bản README trước ghi 4 điều **sai** về dylib mẫu. Sau khi đọc lại từng lệnh assembly:

| Tôi ghi sai | Sự thật (kèm địa chỉ) |
|---|---|
| Preset ladder `HighestQuality → 1920x1080 → 1280x720 → Medium` | Ladder **hạ cấp**, thứ tự thật: **1280x720 trước**, rồi 1920x1080, không có cả hai thì giữ preset gốc (`0x8558`, `0x8590`, `0x85c0`) |
| `setFileLengthLimit` → 500MB | `0x600000` = **6 MB** (`0x8de0`) |
| `setCanPerformMultiplePassesOverSourceMediaData` → YES | **NO** (`0x8e78`) |
| Hằng `0x17c88` = "600 giây" | Đó là **timescale của `kCMTimeZero`** (`value=0, timescale=600, flags=1`), dùng cho `setTransform:atTime:` trong `_FitComposition` — không liên quan thời lượng |
| (ngầm hiểu) dylib này nâng trần quay | **Không hề hook `setMaxRecordedDuration`/`FileSize`**. Nó chỉ hook `-[AVAssetExportSession initWithAsset:presetName:]` (`_ExportInit` @ `0x8420`) |

**Kết luận đúng:** `MHVideoPipeline` là tweak **nén video cho vừa giới hạn upload**, không phải tweak nâng giới hạn. Đó mới là cách video dài thực sự upload được — vì server Locket kiểm dung lượng ở Storage rules.

Vì vậy `LocketPlus` giờ làm **cả hai**, tách bằng config: mặc định nâng trần (600s/500MB) như bạn yêu cầu; bật `compressForUpload` thì chuyển sang chiến lược nén của dylib mẫu.

Bài học: đừng suy ra hành vi từ tên hằng số. `600` trong một `CMTime` là **timescale**, không phải số giây.


## v2.1 — sửa 5 lỗi thật gây crash (đọc từ log thật)

Log của bạn cho thấy 3 sự thật quan trọng:

```
[net] hook 10 method trên 6 class     <- hook quá rộng
crash.txt rỗng (không stack trace)    <- handler chết trong handler
[23:21:18] [boot] sẵn sàng            <- boot XONG rồi mới chết
[23:21:21] (chết)                     <- ~3s sau, không đều
```

### 1. Lỗi gốc: `LPHookMethod` sửa Method của CLASS CHA

Đây là lỗi nghiêm trọng nhất, và nó giải thích tại sao 4 dylib mẫu chạy được còn của tôi thì không.

```objc
// SAI (bản cũ của tôi)
Method m = class_getInstanceMethod(cls, sel);   // ĐI LÊN class cha nếu cls không tự cài
method_setImplementation(m, newImp);            // sửa Method của CHA
// => MỌI subclass đều chạy qua code của tôi
```

```objc
// ĐÚNG (cả 2 dylib mẫu đều làm thế)
// _Hook @0x8364 (MHVideoPipeline), _ObserveMethod @0x4570 (blatantsPatch)
duyệt class_copyMethodList để biết class nào SỞ HỮU method:
  owner == cls  -> method_setImplementation
  owner != cls  -> class_addMethod lên cls   (class cha KHÔNG bị đụng)
```

Với `NSURLSession` (class cluster), bản cũ của tôi còn quét **6 class** và hook **10 method** — gồm cả class private của hệ thống. Mỗi response trong app đều chạy qua code tweak. `AutoRcSideload` hook **đúng 1 class, 2 selector**.

### 2. Crash handler không ghi được gì

Handler cũ dùng `NSMutableString` + `writeToFile:` — Foundation trong signal handler có thể chết (heap hỏng, lock bị giữ) → `crash.txt` chỉ còn template. Giờ dùng `open`/`read`/`write`/`snprintf` thuần POSIX.

### 3. `__got` KHÔNG phải con trỏ PAC

Bản cũ bỏ qua cả `__got` trên arm64e với lý do "con trỏ PAC" → sideload fix không đầy đủ. Sự thật: chỉ **`__auth_got`** là con trỏ đã ký PAC. `blatantsPatch` vá `__got` và chạy được.

### 4. Bỏ 2 thứ tôi tự bịa (không dylib mẫu nào làm)

| Bỏ | Vì sao |
|---|---|
| `LPRemoteConfig` | Hook `boolValue`/`numberValue`/`integerValue`/`stringValue` của **mọi** lần đọc Remote Config trong app. Không mẫu nào làm. Bề mặt crash cực lớn |
| Hook `RCEntitlementInfos` / `RCCustomerInfo` | `AutoRcSideload` chỉ rewrite JSON, không hook class. Value của `.all`/`.active` là object thật; nhân bản dưới nhiều key có thể làm SDK so sánh `identifier != key` |

### 5. `NSUserDefaults`: hook đúng selector private

`blatantsPatch` hook **`_initWithSuiteName:container:`**, không phải `initWithSuiteName:`. Và nó **thay container** bằng thư mục thật — không trả `standardUserDefaults` (làm vậy là trộn dữ liệu app với app-group, và trả object khác class caller mong đợi).

### 6. Không dùng KVC

`MHProfileSupport._FetcherFinished` (@0xd4f0) kiểm `respondsToSelector:` **trước mọi lệnh gửi**. Bản cũ của tôi dùng `[fetcher valueForKey:@"request"]` → `NSUnknownKeyException` chờ xảy ra.

## Nếu vẫn crash

Giờ có thêm công cụ để khoanh vùng. Trong `Documents/LocketPlus/`:

- **`live.trace`** — ghi từng bước hook chạy (net.completion, media.maxDuration…). Crash xảy ra sau boot thì file này cho biết đang ở đâu.
- **`crash.txt`** — giờ có stack trace thật (địa chỉ).
- **`boot.trace`** — bước boot cuối.

Và tắt từng module trong `config.plist` để khoanh vùng:

| Key | Tắt gì |
|---|---|
| `mediaEnabled` | Toàn bộ hook video |
| `goldUnlock` | Gold + xoá cache |
| `friendDiagnostics` | Chẩn đoán kết bạn + GTMSessionFetcher observer |
| `safeMode` | Tất cả |

Cách nhanh nhất: bật `safeMode` (chắc chắn mở được app), rồi bật lại **một** module mỗi lần.
