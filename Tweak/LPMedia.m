// ============================================================================
//  LPMedia.m — trần quay 600s / 500MB
//
//  BÁM SÁT MHVideoPipeline.dylib (đã disassemble):
//    • Hook -[AVCaptureMovieFileOutput setMaxRecordedDuration:] và
//      setMaxRecordedFileSize: → ép về 600s / 500MB.
//    • Hook -[AVAssetExportSession setFileLengthLimit:] / setTimeRange: →
//      nới trần export (đây là chỗ Locket tự cắt video trước khi upload).
//    • setCanPerformMultiplePassesOverSourceMediaData = YES → export video dài
//      không fail giữa đường.
//    • Preset ladder: HighestQuality → 1920x1080 → 1280x720 → Medium.
//
//  TUYỆT ĐỐI KHÔNG hook getter trả struct (CMTime, CMTimeRange, CGRect...).
//  Trên arm64 struct > 16 byte trả qua con trỏ ẩn ở x8 — khai báo sai chữ ký
//  là ghi vào thanh ghi rác → crash (đúng lỗi v1.5/v1.6).
//  Chỉ hook SETTER nhận struct làm THAM SỐ — tham số thì truyền bình thường.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <objc/message.h>

static BOOL gMediaInstalled = NO;

#pragma mark - AVCaptureMovieFileOutput

static void LPMaxDuration(id self, SEL _cmd, CMTime t) {
    double want = LPVideoSeconds();
    double real = CMTimeGetSeconds(t);
    if (isfinite(real) && real > 0 && real < want) {
        LPLog(@"[media] maxRecordedDuration %.0fs → %.0fs", real, want);
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    CMTime v = CMTimeMakeWithSeconds(want, 600);
    ((void (*)(id, SEL, CMTime))o)(self, _cmd, v);
}

static void LPMaxFileSize(id self, SEL _cmd, long long size) {
    long long want = (long long)LPVideoBytes();
    if (size > 0 && size < want) {
        LPLog(@"[media] maxRecordedFileSize %lld → %lld", size, want);
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, long long))o)(self, _cmd, want);
}

#pragma mark - AVAssetExportSession

// Locket tự cắt video trước khi upload: setTimeRange + setFileLengthLimit.
//
// CẨN THẬN: setTimeRange cũng là API người dùng dùng để CẮT video (trim).
// Tự nới range = phá ý định của người dùng (cắt 15s thành 60s).
// Vì vậy mặc định CHỈ GHI LOG. Muốn nới thì bật "expandExportRange" = true
// trong config.plist và tự chịu rủi ro đó.
//
// CMTimeRange là struct 48 byte → arm64 truyền gián tiếp qua con trỏ.
// Khai báo ĐÚNG kiểu struct là compiler tự lo ABI; khai báo sai (void*) là crash.
static void LPExportTimeRange(id self, SEL _cmd, CMTimeRange r) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    CMTimeRange use = r;
    @try {
        double d = CMTimeGetSeconds(r.duration);
        if (isfinite(d) && d > 0) {
            LPLog(@"[media] export timeRange %.1fs (start %.1fs)", d, CMTimeGetSeconds(r.start));
        }
        if ([[LPConfig shared] flag:@"expandExportRange" fallback:NO] &&
            isfinite(d) && d > 0 && d < LPVideoSeconds()) {
            id asset = ((id (*)(id, SEL))objc_msgSend)(self, @selector(asset));
            if (asset) {
                CMTime ad = ((CMTime (*)(id, SEL))objc_msgSend)(asset, @selector(duration));
                double assetSecs = CMTimeGetSeconds(ad);
                if (isfinite(assetSecs) && assetSecs > d + 0.05) {
                    double want = MIN(assetSecs, LPVideoSeconds());
                    use = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(want, 600));
                    LPLog(@"[media] nới timeRange %.1fs → %.1fs", d, want);
                }
            }
        }
    } @catch (__unused NSException *e) {}

    ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, use);
}

static void LPExportFileLengthLimit(id self, SEL _cmd, long long limit) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    long long want = (long long)LPVideoBytes();
    long long use = (limit > 0 && limit < want) ? want : limit;
    if (use != limit) LPLog(@"[media] export fileLengthLimit %lld → %lld", limit, use);
    ((void (*)(id, SEL, long long))o)(self, _cmd, use);
}
// Export video dài cần nhiều pass; không bật thì AVAssetExportSession fail
// giữa đường với video > ~2 phút hoặc > 200MB.
static void LPExportMultiPass(id self, SEL _cmd, BOOL v) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, BOOL))o)(self, _cmd, YES);
}

#pragma mark - UIImagePickerController (bản Locket cũ)

static void LPPickerMaxDuration(id self, SEL _cmd, double secs) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, double))o)(self, _cmd, LPVideoSeconds());
}

#pragma mark - micro

static void LPEnsureAudioSession(void) {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
              mode:AVAudioSessionModeVideoRecording
           options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                   AVAudioSessionCategoryOptionAllowBluetooth
             error:&err];
    if (err) { LPLog(@"[media] audio category lỗi: %@", err.localizedDescription); return; }
    [s setActive:YES withOptions:0 error:&err];
    if (err) LPLog(@"[media] audio active lỗi: %@", err.localizedDescription);
}

static BOOL (*gOrigSetActive)(id, SEL, BOOL, NSUInteger, NSError **);
static BOOL LPSetActive(id self, SEL _cmd, BOOL active, NSUInteger opts, NSError **err) {
    if (!active && [[LPConfig shared] flag:@"keepMicOnRecord" fallback:YES]) {
        LPEnsureAudioSession();
        return YES;
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    return o ? ((BOOL (*)(id, SEL, BOOL, NSUInteger, NSError **))o)(self, _cmd, active, opts, err)
             : NO;
}

static void (*gOrigStartRunning)(id, SEL);
static void LPStartRunning(id self, SEL _cmd) {
    @try {
        if ([[LPConfig shared] flag:@"addMicInput" fallback:YES]) {
            BOOL hasAudio = NO;
            NSArray *inputs = ((NSArray *(*)(id, SEL))objc_msgSend)(self, @selector(inputs));
            if ([inputs isKindOfClass:[NSArray class]]) {
                for (id input in inputs) {
                    NSArray *ports = ((NSArray *(*)(id, SEL))objc_msgSend)(input, @selector(ports));
                    if (![ports isKindOfClass:[NSArray class]]) continue;
                    for (id port in ports) {
                        NSString *t = ((id (*)(id, SEL))objc_msgSend)(port, @selector(mediaType));
                        if ([t isEqualToString:AVMediaTypeAudio]) { hasAudio = YES; break; }
                    }
                    if (hasAudio) break;
                }
            }
            if (!hasAudio) {
                AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
                if (mic) {
                    NSError *e = nil;
                    AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:mic error:&e];
                    if (in && ((BOOL (*)(id, SEL, id))objc_msgSend)(self, @selector(canAddInput:), in)) {
                        ((BOOL (*)(id, SEL, id))objc_msgSend)(self, @selector(addInput:), in);
                        LPLog(@"[media] thêm micro vào session quay");
                    }
                }
            }
            LPEnsureAudioSession();
        }
    } @catch (NSException *e) { LPLog(@"[media] mic: %@", e.reason); }
    if (gOrigStartRunning) gOrigStartRunning(self, _cmd);
}

#pragma mark - install

void LPInstallMediaHooks(void) {
    if (gMediaInstalled) return;
    gMediaInstalled = YES;

    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    BOOL a = LPHookMethodTyped(out, @selector(setMaxRecordedDuration:), "v",
                               (IMP)LPMaxDuration, NULL);
    BOOL b = LPHookMethodTyped(out, @selector(setMaxRecordedFileSize:), "v",
                               (IMP)LPMaxFileSize, NULL);
    LPLog(@"[media] AVCaptureMovieFileOutput duration=%d size=%d", a, b);

    Class exp = NSClassFromString(@"AVAssetExportSession");
    BOOL c = LPHookMethodTyped(exp, @selector(setFileLengthLimit:), "v",
                               (IMP)LPExportFileLengthLimit, NULL);
    BOOL d = LPHookMethodTyped(exp, @selector(setTimeRange:), "v",
                               (IMP)LPExportTimeRange, NULL);
    BOOL e = LPHookMethodTyped(exp, @selector(setCanPerformMultiplePassesOverSourceMediaData:), "v",
                               (IMP)LPExportMultiPass, NULL);
    LPLog(@"[media] AVAssetExportSession limit=%d range=%d multipass=%d", c, d, e);

    Class picker = NSClassFromString(@"UIImagePickerController");
    BOOL f = LPHookMethodTyped(picker, @selector(setVideoMaximumDuration:), "v",
                               (IMP)LPPickerMaxDuration, NULL);
    LPLog(@"[media] UIImagePickerController duration=%d", f);

    Class sess = NSClassFromString(@"AVAudioSession");
    if (LPHookMethod(sess, @selector(setActive:withOptions:error:),
                     (IMP)LPSetActive, (IMP *)&gOrigSetActive)) {
        LPLog(@"[media] AVAudioSession.setActive");
    }

    Class cap = NSClassFromString(@"AVCaptureSession");
    if (LPHookMethod(cap, @selector(startRunning), (IMP)LPStartRunning,
                     (IMP *)&gOrigStartRunning)) {
        LPLog(@"[media] AVCaptureSession.startRunning");
    }

    LPLog(@"[media] trần: %.0fs / %.0fMB", LPVideoSeconds(), LPVideoBytes() / 1048576.0);
}
