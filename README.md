# Locket+ v5.3

Một dylib duy nhất thay cho 4 dylib mẫu, viết lại từ đầu sau khi disassemble
từng lệnh assembly của chúng.

**Tải:** [LocketPlus.dylib](https://github.com/MayMayne/locket-plus/releases/latest)

---

## Làm được gì

| Tính năng | Mặc định | Config |
|---|---|---|
| Quay video tối đa **10 phút / 500 MB** | ✅ | `maxRecordSeconds`, `maxRecordBytes` |
| Chế độ quay nhanh **60 giây** | tắt | `quickMode` |
| **Micro** khi quay (thêm input + giữ audio session) | ✅ | `addMicInput`, `keepAudioSession` |
| Up từ thư viện tối đa **60 giây / 15 MB** | ✅ | `maxUploadSeconds`, `maxUploadBytes` |
| **Tỉ lệ khung** 9:16 · 16:9 · 1:1 (đệm nền, không cắt hình) | `auto` | `frameRatioDefault` |
| **Gold** phía client | ✅ | `goldEnabled` |
| Sống sót khi sideload (không mất đăng nhập) | ✅ | `sideloadFix` |

Tỉ lệ **6:19 / 19:6** là cách gọi khác của **9:16 / 16:9** — đặt
`frameRatioDefault` = `"9:16"` hoặc `"16:9"`.

---

## Cài

### Cách 1 — tiêm vào IPA có sẵn (khuyến nghị)

```sh
cp LocketPlus.dylib Payload/Locket.app/Frameworks/
python3 tools/insert_dylib.py Payload/Locket.app/Locket \
        "@executable_path/Frameworks/LocketPlus.dylib"
ldid -S Payload/Locket.app/Locket
```

Hoặc dùng script có sẵn:

```sh
./tools/inject.sh Locket.ipa LocketPlus.ipa LocketPlus.dylib
```

`insert_dylib.py` ghi load command vào **vùng đệm của header**, không dịch
chuyển byte nào. Chèn byte vào đầu `__TEXT` sẽ làm mọi `fileoff` lệch → app
chết ngay khi mở. Đây là lỗi phổ biến của các script tiêm tự viết.

### Cách 2 — thay thế 4 dylib mẫu

Xoá `blatantsPatch.dylib`, `AutoRcSideload.dylib`, `MHVideoPipeline.dylib`,
`MHProfileVideo.dylib` khỏi `Frameworks/` rồi tiêm `LocketPlus.dylib` như trên.

> **Đừng chạy song song.** `LocketPlus` đã làm đủ 3 việc của 3 dylib đầu.
> Chạy cùng nhau là hook trùng → hành vi không xác định.

---

## Cấu hình

File `config.plist` đặt ở một trong hai chỗ:

1. `<container>/Documents/LocketPlus/config.plist` — sửa được lúc chạy
2. `Locket.app/LocketPlus.plist` — đóng gói sẵn trong IPA

Lần chạy đầu, nếu không có file nào, dylib tự ghi bản mặc định vào (1).

```xml
<dict>
    <!-- trần QUAY: 10 phút / 500MB -->
    <key>maxRecordSeconds</key>     <real>600</real>
    <key>maxRecordBytes</key>       <real>524288000</real>

    <!-- quay nhanh 60s: bật bằng quickMode, hoặc tạo file quick.on -->
    <key>quickMode</key>            <false/>
    <key>quickRecordSeconds</key>   <real>60</real>

    <!-- trần UP từ thư viện -->
    <key>maxUploadSeconds</key>     <real>60</real>
    <key>maxUploadBytes</key>       <real>15728640</real>

    <!-- tỉ lệ khung: auto | 9:16 | 16:9 | 1:1 | ask -->
    <key>frameRatioDefault</key>    <string>auto</string>
    <key>frameBackground</key>      <string>000000</string>

    <key>goldEnabled</key>          <true/>
    <key>addMicInput</key>          <true/>
    <key>logVerbose</key>           <true/>
</dict>
```

`frameRatioDefault = "ask"` → hỏi bằng action sheet mỗi lần export (timeout
20 giây thì tự chạy `auto`, không treo).

---

## Log & chẩn đoán

`<container>/Documents/LocketPlus/`

| File | Nội dung |
|---|---|
| `log.txt` | từng bước hook, giới hạn đã áp, response RevenueCat đã vá |
| `crash.txt` | signal + backtrace thật (POSIX, không dùng Foundation) |
| `crash.count` | số lần chết liên tiếp |

**Safe mode:** chết 2 lần liên tiếp → tự bật, chỉ ghi log, không hook gì.
Boot sạch 2 lần trong safe mode → tự tắt. Bật tay: `safeMode = true`.
Không bao giờ bật chỉ vì bạn vuốt tắt app (đếm theo kích thước `crash.txt`,
không đếm số lần mở app).

---

## Đã bám dylib mẫu ở đâu

| Dylib mẫu | Kỹ thuật lấy được | Ghi chú |
|---|---|---|
| `blatantsPatch` | canary keychain → đọc access group thật → fishhook `SecItem*` **thay** group (không xoá) → swizzle `containerURL` + `_initWithSuiteName:container:` | Bản mẫu quét `__got`; ta quét thêm `__la_symbol_ptr`/`__nl_symbol_ptr` và **bỏ qua `__auth_got`** (con trỏ PAC) |
| `AutoRcSideload` | rewrite JSON RevenueCat ở tầng `NSURLSession` completion handler | Chỉ 1 class, 2 selector — đúng như binary mẫu |
| `MHVideoPipeline` | preset ladder 720p→1080p, `fileLengthLimit`, `AVMutableVideoComposition` đệm khung | Mẫu **nén** chứ không nâng trần; ta làm cả hai, tách bằng config |
| `MHProfileVideo` | không gộp | video bìa profile, không nằm trong yêu cầu |

### 3 chỗ bản mẫu làm sai/thiếu, đã sửa

1. **`_Configure` set `fileLengthLimit` = 6 MB cho MỌI export.** Video 10 phút
   sẽ fail. Ta dùng ngân sách theo độ dài: ≤60s → 15 MB, dài hơn → 500 MB.
2. **`setCanPerformMultiplePassesOverSourceMediaData: NO`** — đúng cho máy yếu,
   nhưng làm giảm chất lượng khi nén mạnh. Ta để mặc định NO như mẫu.
3. **Không đụng `setTimeRange`** — đúng. Ta cũng không đụng, trừ khi bật
   `trimToUpload` (mặc định tắt), vì nới/cắt timeRange là phá thao tác trim
   của người dùng.

---

## Giới hạn thật (đọc kỹ)

- **Gold là client-side.** Server Locket vẫn coi tài khoản là free:
  - Badge Gold trên profile **người khác xem** không hiện (server ghi đè).
  - Hạn mức kết bạn phía server **không đổi**.
  - Giao dịch thật vẫn qua App Store.
- **Trần 500 MB / 10 phút** là trần *ghi hình trên máy*. Server Locket có
  Storage rules riêng; nếu upload bị từ chối vì dung lượng, bật
  `compressShortUploads` (mặc định bật) hoặc giảm `maxRecordBytes`.
- **Kết bạn** không nằm trong bản này. Nó bị chặn ở App Check / Cloud
  Functions phía server, không sửa được từ client.

---

## Build

```sh
./build.sh            # cần Xcode + SDK iOS
```

CI: GitHub Actions trên `macos-26`, đẩy tag `dylib-<run_id>` kèm artifact.

## Cấu trúc

```
Tweak/
  LPCommon.h/.m    config, log thread-safe, hook an toàn, tầng mạng
  LPCrash.m        crash handler POSIX + safe mode
  LPSideload.m     fishhook SecItem* + app group + NSUserDefaults suite
  LPGold.m         rewrite JSON RevenueCat
  LPMedia.m        trần quay, mic, tỉ lệ khung, preset ladder
  LPEntry.m        thứ tự khởi động
tools/
  insert_dylib.py  tiêm load command vào vùng đệm (an toàn)
  inject.sh        tiêm + ký + đóng gói IPA
```
