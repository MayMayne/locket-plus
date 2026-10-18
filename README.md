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

## Sự thật kỹ thuật về 3 yêu cầu

1. **Kết bạn trên bản IPA sideload**
   - `sendFriendRequest` / `acceptFriendRequest` là Cloud Function trên project `locket-4252a`.
   - Nếu lỗi do **token đăng nhập hết hạn** (keychain bị đứt vì patch sideload) → `LPFriend.m` tự refresh ID token + replay **sẽ cứu được**.
   - Nếu server bật **App Check ở mức attestation bắt buộc** cho team gốc `SWD4AZY4KG` → bản IPA ký bằng chứng chỉ khác **không thể tự tạo attestation hợp lệ** từ phía client. Màn hình **Chẩn đoán kết bạn** sẽ in rõ `HTTP` + `body` sau khi replay để bạn biết mình rơi vào trường hợp nào.

2. **Quay 10 phút / 500MB**
   - Trần ở **client** (`AVCaptureMovieFileOutput`, `UIImagePickerController`, `AVAssetExportSession`, kiểm tra `AVAsset.duration` / `NSFileSize`) đều đã bị nâng lên `600s` và `500MB` (sửa được trong `config.plist`).
   - Nếu Locket có thêm một hàm Swift riêng kiểu `maxVideoDuration` → mở **L+ → Runtime Explorer → Quét method** gõ `duration` hoặc `size`, lấy tên `Class` + `selector` rồi điền vào mục `patches` của `config.plist` là ăn ngay, không cần biên dịch lại.
   - Lưu ý: nếu **server** giới hạn kích thước upload ở tầng Cloud Storage Rules / transcode backend thì phần vượt trần server vẫn sẽ bị từ chối lúc upload (log `[net] upload` sẽ ghi rõ).

3. **Trang Profile+ mới**
   - Mở từ nút **✨** trong menu profile của Locket hoặc từ **L+ → Mở Profile+**.
   - Chạm ảnh bìa / avatar để đổi ảnh, chạm ✏️ để sửa tên + quote + bài hát + ca sĩ + lyric, nút `+` để thêm ảnh tiêu biểu hoặc bạn thân (kèm chữ huy hiệu tuỳ chọn như `★ Bestie`, `💛 Bạn thân`).
   - Toàn bộ dữ liệu lưu cục bộ tại `Documents/LocketPlus/profile.plist` + ảnh `.jpg` cùng thư mục. (Chỉ hiển thị trên máy bạn; server Locket không có trường dữ liệu cho các mục này.)

---

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
