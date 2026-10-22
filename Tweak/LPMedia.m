// ============================================================================
//  LPMedia.m — 600 giây / 500 MB
//
//  CHỈ 2 setter. Không preset ladder, không audio session, không mic,
//  không export timeRange, không hook AVAssetExportSession.
//
//  Lý do chỉ 2 setter:
//    • AVCaptureMovieFileOutput.maxRecordedDuration  → trần thời lượng quay
//    • AVCaptureMovieFileOutput.maxRecordedFileSize  → trần dung lượng file
//  Đây là 2 API DUY NHẤT quyết định Locket cho quay bao lâu / bao to.
//  Mọi thứ khác (export, preset, audio) là suy diễn thêm của tôi và đã gây crash.
//
//  ABI: CMTime là struct 24 byte, truyền làm THAM SỐ thì compiler tự lo.
//  TUYỆT ĐỐI không hook getter trả struct (struct > 16 byte trả qua con trỏ
//  ẩn ở x8 trên arm64) — đó là lỗi v1.5/v1.6.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

static void LPMaxDuration(id self, SEL _cmd, CMTime t) {
    IMP o = LPOrigIMPFor(object_getClass(self), _cmd);
    if (!o) o = LPOrigIMPFor(NSClassFromString(@"AVCaptureMovieFileOutput"), _cmd);
    if (!o) return;

    double want = LPVideoSeconds();
    double real = CMTimeGetSeconds(t);
    if (isfinite(real) && real > 0 && real < want) {
        LPLog(@"[media] maxRecordedDuration %.0fs → %.0fs", real, want);
    }
    ((void (*)(id, SEL, CMTime))o)(self, _cmd, CMTimeMakeWithSeconds(want, 600));
}

static void LPMaxFileSize(id self, SEL _cmd, long long size) {
    IMP o = LPOrigIMPFor(object_getClass(self), _cmd);
    if (!o) o = LPOrigIMPFor(NSClassFromString(@"AVCaptureMovieFileOutput"), _cmd);
    if (!o) return;

    long long want = (long long)LPVideoBytes();
    if (size > 0 && size < want) {
        LPLog(@"[media] maxRecordedFileSize %lld → %lld", size, want);
    }
    ((void (*)(id, SEL, long long))o)(self, _cmd, want);
}

void LPInstallMediaHooks(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    if (!out) {
        LPLog(@"[media] KHÔNG có AVCaptureMovieFileOutput");
        return;
    }

    BOOL a = LPHookMethodTyped(out, @selector(setMaxRecordedDuration:), "v",
                               (IMP)LPMaxDuration, NULL);
    BOOL b = LPHookMethodTyped(out, @selector(setMaxRecordedFileSize:), "v",
                               (IMP)LPMaxFileSize, NULL);

    LPLog(@"[media] duration=%d size=%d → %.0fs / %.0fMB",
          a, b, LPVideoSeconds(), LPVideoBytes() / 1048576.0);
}
