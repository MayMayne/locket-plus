# LocketPlus (`LocketPlus.dylib`)

Dự án tweak Objective-C tự đóng gói cho **Locket 2.68+**, gồm 4 khối:

| Tệp | Chức năng |
|---|---|
| `Tweak/LPMedia.m` | Phá trần quay phim: `maxRecordedDuration` → **600s**, `maxRecordedFileSize` → **500MB**, mở lại `AVAssetExportSession.timeRange`, báo thời lượng/dung lượng đã thu gọn để qua validator client |
| `Tweak/LPFriend.m` | Chẩn đoán kết bạn (móc `NSURLSession` + `GTMSessionFetcher`), khi bị **401/403** tự ép làm mới `FIRAuth` ID token + `FIRAppCheck` token rồi **replay 1 lần** |
| `Tweak/LPProfile.m` | Trang **Profile+** riêng: ảnh bìa, ảnh đại diện, quote, bài hát + ca sĩ + lyric, bộ sưu tập ảnh tiêu biểu, danh sách bạn thân kèm **huy hiệu bạn thân** vàng |
| `Tweak/LPExplorer.m` + `LPPatch.m` | **Runtime Explorer** tìm class/method ngay trên máy + bộ vá cấu hình trong `Documents/LocketPlus/config.plist` (không cần build lại khi Locket đổi tên hàm) |
| `Tweak/LPEntry.m` | Nút nổi **L+** (chạm = mở hub, giữ = chẩn đoán kết bạn) + tự gắn nút ✨ vào `ProfileMenuV2ViewController` |

---

## Sự thật kỹ thuật (đã kiểm chứng trên binary 2.68 + dylib mẫu)

### 1. Kết bạn trên IPA sideload — **không phá được ở client**
- `sendFriendRequest` / `acceptFriendRequest` là Cloud Function (project `locket-4252a`), server kiểm `X-Firebase-AppCheck`.
- Bản ký lại bằng chứng chỉ khác **không tạo được attestation hợp lệ** cho team `SWD4AZY4KG`. Refresh token không tạo ra attestation.
- `MHProfileSupport.dylib` (bản V28) làm đúng một việc: **ép refresh ID token + App Check token khi gặp 401 rồi replay** — chỉ cứu được trường hợp token cũ/hỏng (keychain đứt khi sideload), không cứu được 403 App Check.
- `LocketPlus` làm điều tương tự nhưng có log rõ ràng, và **phân biệt 401 vs 403**:
  - `401` → tự refresh ID token + replay 1 lần (có thể cứu).
  - `403` → log thẳng: App Check, bản sideload thua.
- Đường duy nhất còn lại: cài bằng **TrollStore / jailbreak giữ nguyên chữ ký gốc**, hoặc để **người dùng bản App Store gốc** bấm accept link mời của bạn.

### 2. Video 10 phút / 500MB — client thì phá được, server thì không
- Đã nới: `AVCaptureMovieFileOutput.maxRecordedDuration / maxRecordedFileSize`, `AVAssetExportSession.timeRange / fileLengthLimit`, `UIImagePickerController.videoMaximumDuration`.
- **Chọn video từ thư viện (PHPicker) không có setter để hook** — Locket 2.68 dùng PHPicker, nên "chọn video 10 phút" vẫn bị app kiểm duration/size sau khi load. Muốn phá phải dùng Runtime Explorer tìm hàm kiểm tra rồi thêm vào `patches`.
- **Upload vẫn bị server chặn**: Storage rules + Cloud Function kiểm duration/size. Hook client chỉ giúp quay/chọn được, không giúp upload được.
- Nút quay có progress ring do ViewModel Swift đếm — giữ tay 10 phút có thể bị UI tự ngắt dù trần đã nới.

### 3. Trang Profile+ (ảnh bìa, avatar, quote, nhạc + lyric, ảnh tiêu biểu, bạn thân + huy hiệu)
- Hoàn toàn **cục bộ** (`Documents/LocketPlus/`). Server Locket không có trường cho các mục này nên người khác không thấy.

---

## Những lỗi đã sửa ở v1.3 (bản cũ crash ngay khi mở app)

| Lỗi | Hậu quả | Sửa |
|---|---|---|
| Hook `-[GTMSessionFetcher startWithCompletionHandler:]` rồi KVC `request`/`response` | Class không có property đó → **NSException mỗi request** → app chết | Bỏ; hook `NSURLSession` và chỉ bọc request kết bạn |
| Hook `-[AVAsset duration]` | Nổ ngay khi đọc duration video | Bỏ (getter này cũng không chặn được gì) |
| Hook `-[NSFileManager attributesOfItemAtPath:error:]` | Chạy liên tục, ghi đè `NSFileSize` làm đọc file lỗi | Bỏ |
| Hook `viewDidAppear:` của class Swift trong constructor | Class chưa tồn tại → hook không bao giờ gắn | `LPWhenClassReady` chờ class rồi mới hook |
| `patches` trong config bị đánh dấu "đã xử lý" khi class chưa có | Patch im lặng không có tác dụng | Chỉ đánh dấu sau khi hook thành công |
| `LPHook` ghi IMP gốc của chính mình khi hook lặp | Hook chồng hook → đệ quy | `LPHookMethod` kiểm tra trùng |

## Cách build `LocketPlus.dylib`

### Cách A — GitHub Actions (không cần máy Mac)
1. Đẩy thư mục này lên một repo GitHub.
2. Vào tab **Actions → Build LocketPlus.dylib → Run workflow**.
3. Tải artifact **`LocketPlus.dylib`**.

### Cách B — Máy Mac có Xcode
```sh
chmod +x build.sh
./build.sh
# -> build/LocketPlus.dylib
```

---

## Cách tiêm vào IPA

- **Bằng Cyan / ESign / Feather / Sideloadly**: chọn IPA Locket → mục *Inject dylib* → thêm `LocketPlus.dylib` → ký và cài.
- **Bằng script đi kèm** (`pip install lief`):
  ```sh
  python3 tools/inject.py --ipa Locket.ipa Locket-Plus.ipa build/LocketPlus.dylib
  ```
  Sau đó cài `Locket-Plus.ipa` qua TrollStore hoặc ký bằng Sideloadly/SideStore.
