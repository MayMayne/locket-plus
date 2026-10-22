#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>

//
// LPMedia — phá trần quay/chọn video.
//
// ĐÃ BỎ so với bản trước (đây là lỗi làm app chết):
//   - hook -[AVAsset duration]  → chỉ cần đọc duration của video là nổ, và hook
//     getter vốn KHÔNG chặn được giới hạn nào vì app đọc từ Swift property.
//   - hook -[NSFileManager attributesOfItemAtPath:error:] → chạy hàng nghìn lần,
//     và ghi đè NSFileSize làm Locket đọc file lỗi.
//   - hook -[NSURLSession uploadTaskWithRequest:fromData:] → chữ ký block dễ sai,
//     upload ảnh/video nào cũng đi qua đây.
//
// TUYỆT ĐỐI KHÔNG hook getter trả struct (CMTime, CMTimeRange, CGRect...):
// arm64 trả struct >16 byte qua con trỏ ẩn ở x8, không phải tham số thứ 3.
// Khai báo sai chữ ký = ghi vào thanh ghi rác = crash ngay.
//
// GIỚI HẠN THẬT CỦA LOCKET (đọc từ binary 2.68):
//   * Quay: AVCaptureMovieFileOutput.maxRecordedDuration / maxRecordedFileSize  (client)
//   * Chọn từ thư viện: PHPicker (KHÔNG dùng UIImagePickerController) → lọc bằng
//     PHPickerFilter + kiểm tra duration/size sau khi load, không có setter để hook.
//   * Upload: Storage rules + Cloud Function kiểm duration/size  (server, không phá được)
//

static BOOL gMediaHooksInstalled = NO;

static void LPMHook(Class cls, SEL sel, IMP newImp) {
    if (LPHookMethod(cls, sel, newImp, NULL)) {
        LPLog(@"[media] hook %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel));
    } else {
        LPLog(@"[media] bỏ qua %@.%@ (không có)", cls ? NSStringFromClass(cls) : @"nil", NSStringFromSelector(sel));
    }
}

#pragma mark - AVCaptureMovieFileOutput: trần quay

static void LPMovieMaxDurationSet(id self, SEL _cmd, CMTime t) {
    double secs = CMTimeGetSeconds(t);
    if (secs > 0 && !isnan(secs)) LPLog(@"[media] maxRecordedDuration thật = %.1fs -> ép %.0fs", secs, LPVideoSeconds());
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, CMTime))o)(self, _cmd, CMTimeMakeWithSeconds(LPVideoSeconds(), 600));
}

static void LPMovieMaxSizeSet(id self, SEL _cmd, long long size) {
    LPLog(@"[media] maxRecordedFileSize thật = %lld -> ép %.0f", size, LPVideoBytes());
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, long long))o)(self, _cmd, (long long)LPVideoBytes());
}

#pragma mark - AVAssetExportSession: đừng để app tự cắt ngắn

// Chỉ nới khi range bị cắt ngắn hơn asset — không bao giờ kéo dài quá độ dài thật.
static void LPExportTimeRangeSet(id self, SEL _cmd, CMTimeRange r) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    if (![[LPConfig shared] flag:@"widenExportRange" fallback:YES]) {
        ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, r);
        return;
    }
    AVAsset *asset = nil;
    @try { asset = [self valueForKey:@"asset"]; } @catch (__unused NSException *e) {}
    if (asset && CMTIME_IS_VALID(asset.duration)) {
        double full = CMTimeGetSeconds(asset.duration);
        double end = CMTimeGetSeconds(CMTimeRangeGetEnd(r));
        if (full > 0 && end > 0 && end < full - 0.05) {
            LPLog(@"[media] export 0→%.2fs của asset %.2fs -> mở hết", end, full);
            ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, CMTimeRangeMake(kCMTimeZero, asset.duration));
            return;
        }
    }
    ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, r);
}

static void LPExportFileLengthSet(id self, SEL _cmd, long long limit) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, long long))o)(self, _cmd, (long long)LPVideoBytes());
}

#pragma mark - UIImagePickerController (Locket 2.68 không dùng, để dành cho bản cũ)

static void LPPickerMaxDurSet(id self, SEL _cmd, double secs) {
    LPLog(@"[media] videoMaximumDuration thật = %.1fs -> ép %.0fs", secs, LPVideoSeconds());
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, double))o)(self, _cmd, LPVideoSeconds());
}

#pragma mark - install

void LPInstallMediaHooks(void) {
    if (gMediaHooksInstalled) return;
    gMediaHooksInstalled = YES;

    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    LPMHook(out, @selector(setMaxRecordedDuration:), (IMP)LPMovieMaxDurationSet);
    LPMHook(out, @selector(setMaxRecordedFileSize:), (IMP)LPMovieMaxSizeSet);

    Class exp = NSClassFromString(@"AVAssetExportSession");
    LPMHook(exp, @selector(setTimeRange:), (IMP)LPExportTimeRangeSet);
    LPMHook(exp, @selector(setFileLengthLimit:), (IMP)LPExportFileLengthSet);

    Class picker = NSClassFromString(@"UIImagePickerController");
    LPMHook(picker, @selector(setVideoMaximumDuration:), (IMP)LPPickerMaxDurSet);

    LPLog(@"[media] trần đặt: %.0fs / %.0fMB", LPVideoSeconds(), LPVideoBytes() / 1048576.0);
}
