// ============================================================================
//  LPMedia.m — v6.3
//
//  SỰ THẬT rút ra từ log THẬT của user (bản v6.2):
//
//      [probe] canAddInput: AVCaptureDeviceInput → 1
//      [probe] addInput: NSKVONotifying_AVCaptureDeviceInput → 0
//      [probe] addOutput: AVCaptureVideoDataOutput
//      (app chết ngay sau dòng này)
//
//  1. Locket KHÔNG dùng AVCaptureMovieFileOutput.
//     Nó dùng AVCaptureVideoDataOutput + AVAssetWriter: tự lấy từng frame rồi
//     tự ghi file. Vì vậy setMaxRecordedDuration / setMaxRecordedFileSize
//     KHÔNG BAO GIỜ được gọi → hook chúng là vô nghĩa. Đây là lý do "quay được
//     có 15 giây" suốt 8 bản: tôi hook đúng API nhưng sai class.
//
//  2. Session của Locket chỉ có VIDEO input, không có audio.
//     addInput cho audio trả về 0. Và kể cả thêm được input thì AVAssetWriter
//     của Locket cũng không có audio writer input → file vẫn không có tiếng.
//     Muốn có mic phải sửa cả pipeline ghi của Locket, không phải thêm input.
//
//  3. Giới hạn 15 giây nằm trong code Swift của Locket (timer hoặc hằng số),
//     KHÔNG phải AVFoundation. Muốn nới phải có binary Locket để tìm đúng hàm.
//
//  VÌ VẬY bản này:
//    • BỎ toàn bộ hook MovieFileOutput (vô dụng, chỉ gây nhiễu log).
//    • BỎ toàn bộ code mic (không thể hoạt động, và là thứ làm app chết).
//    • BỎ probe addInput/addOutput (có thể can thiệp vào session của Locket).
//    • GIỮ những gì thật sự có tác dụng và đã kiểm chứng từ dylib mẫu:
//        - nâng fileLengthLimit (chỉ nâng, không hạ)
//        - nới timeout upload lên 288s  ← đây là fix "không up được video"
//        - nới videoMaximumDuration của picker
//    • Probe mới CHỈ đọc, chỉ đụng AVAssetWriter, không đụng capture session.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/message.h>
#import <math.h>

static BOOL gMediaInstalled = NO;

#pragma mark - UIImagePickerController (chọn video từ thư viện)

static void LPPickerMaxDuration(id self, SEL _cmd, double secs) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, double))o)(self, _cmd, LPUploadSeconds());
}

#pragma mark - AVAssetExportSession: CHỈ NÂNG giới hạn

// fileLengthLimit là NGƯỠNG CỨNG: vượt là export FAIL, không phải file nhỏ đi.
// Vì vậy chỉ được NÂNG, KHÔNG BAO GIỜ HẠ.
// (Bản v5.0–v5.7 hạ xuống 15MB cho clip ngắn → mọi video 60s đều fail.)
static void LPExportFileLengthLimit(id self, SEL _cmd, long long limit) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    long long want = (long long)LPMaxRecordBytes();
    long long use = (limit > 0 && limit < want) ? want : limit;
    if (use != limit) LPLog(@"[media] fileLengthLimit %lld → %lld (nâng)", limit, use);
    ((void (*)(id, SEL, long long))o)(self, _cmd, use);
}

#pragma mark - install

void LPInstallMedia(void) {
    if (gMediaInstalled) return;
    gMediaInstalled = YES;

    if (![[LPConfig shared] flag:@"mediaEnabled" fallback:YES]) {
        LPLog(@"[media] tắt theo config");
        return;
    }

    // Nâng ngưỡng dung lượng export — chỉ nâng, không hạ.
    Class exp = NSClassFromString(@"AVAssetExportSession");
    BOOL a = LPHookMethodTyped(exp, @selector(setFileLengthLimit:), "v",
                               (IMP)LPExportFileLengthLimit, NULL);

    // Chọn video từ thư viện.
    Class picker = NSClassFromString(@"UIImagePickerController");
    BOOL b = LPHookMethodTyped(picker, @selector(setVideoMaximumDuration:), "v",
                               (IMP)LPPickerMaxDuration, NULL);

    LPLog(@"[media] fileLengthLimit(nâng)=%d picker=%d · upload %.0fs / %.0fMB",
          a, b, LPUploadSeconds(), LPUploadBytes() / 1048576.0);

    // KHÔNG hook AVCaptureMovieFileOutput: Locket không dùng nó.
    // KHÔNG thêm mic: pipeline ghi của Locket không có audio track.
    LPLog(@"[media] KHÔNG hook capture session (Locket dùng AVCaptureVideoDataOutput)");
}
