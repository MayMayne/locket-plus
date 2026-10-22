// ============================================================================
//  LPProbe.m — CHỈ GHI LOG, KHÔNG SỬA GÌ
//
//  Mục đích: tìm ra Locket thật sự dùng class nào để quay video và đặt giới
//  hạn 15 giây ở đâu.
//
//  Bằng chứng khiến phải làm việc này (log của user, bản v5.6):
//      [media] AVCaptureMovieFileOutput duration=1 size=1   ← hook cài OK
//      (KHÔNG có dòng "maxRecordedDuration 15s → 600s")
//      [media] thêm micro vào session quay: 0               ← addInput fail
//
//  Nghĩa là Locket KHÔNG gọi -[AVCaptureMovieFileOutput setMaxRecordedDuration:].
//  Vậy 15 giây đến từ chỗ khác: AVAssetWriter, hoặc một lớp wrapper của Locket,
//  hoặc Remote Config. Không đoán nữa — log ra rồi xem.
//
//  Mọi hook ở đây chỉ NSLog, gọi IMP gốc y nguyên, không đổi tham số.
//  Tắt bằng `probeEnabled = false` sau khi tìm ra.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static BOOL gProbeOn = NO;

#define PROBE(fmt, ...) do { if (gProbeOn) LPLog(@"[probe] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - AVCaptureSession: xem Locket lắp gì vào session

static void (*gPAddOutput)(id, SEL, id);
static void LPProbeAddOutput(id self, SEL _cmd, id output) {
    PROBE("addOutput: %s", output ? object_getClassName(output) : "(nil)");
    if (gPAddOutput) ((void (*)(id, SEL, id))gPAddOutput)(self, _cmd, output);
}

static BOOL (*gPAddInput)(id, SEL, id);
static BOOL LPProbeAddInput(id self, SEL _cmd, id input) {
    NSString *mt = @"?";
    @try {
        if ([input respondsToSelector:@selector(device)]) {
            id dev = ((id (*)(id, SEL))objc_msgSend)(input, @selector(device));
            if ([dev respondsToSelector:@selector(mediaType)])
                mt = ((id (*)(id, SEL))objc_msgSend)(dev, @selector(mediaType));
        }
    } @catch (__unused NSException *e) {}
    BOOL r = gPAddInput ? ((BOOL (*)(id, SEL, id))gPAddInput)(self, _cmd, input) : NO;
    PROBE("addInput: %s mediaType=%@ → %d", input ? object_getClassName(input) : "(nil)", mt, r);
    return r;
}

static BOOL (*gPCanAddInput)(id, SEL, id);
static BOOL LPProbeCanAddInput(id self, SEL _cmd, id input) {
    BOOL r = gPCanAddInput ? ((BOOL (*)(id, SEL, id))gPCanAddInput)(self, _cmd, input) : NO;
    PROBE("canAddInput: %s → %d", input ? object_getClassName(input) : "(nil)", r);
    return r;
}

#pragma mark - AVCaptureMovieFileOutput: xem trần THẬT lúc bắt đầu ghi

static NSTimeInterval gProbeRecStart = 0;

static void (*gPStartRec)(id, SEL, NSURL *, id);
static void LPProbeStartRecording(id self, SEL _cmd, NSURL *url, id delegate) {
    gProbeRecStart = [NSDate timeIntervalSinceReferenceDate];
    @try {
        double dur = -1, size = -1;
        if ([self respondsToSelector:@selector(maxRecordedDuration)]) {
            CMTime t = ((CMTime (*)(id, SEL))objc_msgSend)(self, @selector(maxRecordedDuration));
            dur = CMTimeGetSeconds(t);
        }
        if ([self respondsToSelector:@selector(maxRecordedFileSize)]) {
            size = (double)((long long (*)(id, SEL))objc_msgSend)(self,
                                                                 @selector(maxRecordedFileSize));
        }
        PROBE("startRecording: maxDuration=%.1fs maxFileSize=%.0fMB",
              dur, size / 1048576.0);
    } @catch (__unused NSException *e) {}
    if (gPStartRec) ((void (*)(id, SEL, NSURL *, id))gPStartRec)(self, _cmd, url, delegate);
}

// ĐÂY LÀ CÂU TRẢ LỜI CHO "15 GIÂY".
// Nếu Locket dùng TIMER để tự dừng sau 15s thì stopRecording sẽ được gọi với
// elapsed ≈ 15.0 và maxRecordedDuration = 0 (không đặt) hoặc rất lớn.
// Nếu Locket dùng maxRecordedDuration thì elapsed sẽ ≈ 15 và maxDuration = 15.
static void (*gPStopRec)(id, SEL);
static void LPProbeStopRecording(id self, SEL _cmd) {
    NSTimeInterval el = gProbeRecStart > 0
        ? [NSDate timeIntervalSinceReferenceDate] - gProbeRecStart : -1;
    double dur = -1;
    @try {
        if ([self respondsToSelector:@selector(maxRecordedDuration)]) {
            CMTime t = ((CMTime (*)(id, SEL))objc_msgSend)(self, @selector(maxRecordedDuration));
            dur = CMTimeGetSeconds(t);
        }
    } @catch (__unused NSException *e) {}
    PROBE("stopRecording sau %.2fs (maxDuration=%.1fs) ← 15s ở đây nghĩa là TIMER",
          el, dur);
    if (gPStopRec) ((void (*)(id, SEL))gPStopRec)(self, _cmd);
}

#pragma mark - AVAssetWriter: đường quay video tự dựng

static id (*gPWriterInit)(id, SEL, NSURL *, NSString *, NSError **);
static id LPProbeWriterInit(id self, SEL _cmd, NSURL *url, NSString *type, NSError **err) {
    id r = gPWriterInit ? ((id (*)(id, SEL, NSURL *, NSString *, NSError **))gPWriterInit)
                            (self, _cmd, url, type, err) : nil;
    PROBE("AVAssetWriter init fileType=%@ ok=%d", type, r != nil);
    return r;
}

static BOOL (*gPStartSession)(id, SEL, CMTime);
static BOOL LPProbeStartSession(id self, SEL _cmd, CMTime t) {
    BOOL r = gPStartSession ? ((BOOL (*)(id, SEL, CMTime))gPStartSession)(self, _cmd, t) : NO;
    PROBE("AVAssetWriter startSessionAtSourceTime: %.2fs → %d", CMTimeGetSeconds(t), r);
    return r;
}

#pragma mark - Locket wrapper (nếu có): tìm class có tên chứa video/capture

static void LPProbeSweep(void) {
    // Liệt kê class của app có tên liên quan — để biết Locket bọc camera ở đâu.
    static const char *keys[] = { "Video", "Capture", "Camera", "Recorder", "Movie" };
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return;

    Class *all = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (!all) return;
    total = objc_getClassList(all, total);

    for (int i = 0; i < total; i++) {
        const char *n = class_getName(all[i]);
        if (!n) continue;
        // Chỉ quan tâm class của Locket (thường có prefix module Swift).
        if (!strstr(n, "Locket") && !strstr(n, "Journal") && !strstr(n, "Camera")) continue;
        for (size_t k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
            if (strstr(n, keys[k])) { PROBE("class: %s", n); break; }
        }
    }
    free(all);
}

#pragma mark - install

void LPInstallProbe(void) {
    gProbeOn = [[LPConfig shared] flag:@"probeEnabled" fallback:NO];
    if (!gProbeOn) return;

    Class sess = NSClassFromString(@"AVCaptureSession");
    if (sess) {
        LPHookMethod(sess, @selector(addOutput:), (IMP)LPProbeAddOutput, (IMP *)&gPAddOutput);
        LPHookMethod(sess, @selector(addInput:), (IMP)LPProbeAddInput, (IMP *)&gPAddInput);
        LPHookMethod(sess, @selector(canAddInput:), (IMP)LPProbeCanAddInput, (IMP *)&gPCanAddInput);
    }

    Class mfo = NSClassFromString(@"AVCaptureMovieFileOutput");
    if (mfo) {
        LPHookMethod(mfo, @selector(startRecordingToOutputFileURL:recordingDelegate:),
                     (IMP)LPProbeStartRecording, (IMP *)&gPStartRec);
        LPHookMethod(mfo, @selector(stopRecording),
                     (IMP)LPProbeStopRecording, (IMP *)&gPStopRec);
    }

    Class writer = NSClassFromString(@"AVAssetWriter");
    if (writer) {
        LPHookMethod(writer, @selector(initWithURL:fileType:error:),
                     (IMP)LPProbeWriterInit, (IMP *)&gPWriterInit);
        LPHookMethod(writer, @selector(startSessionAtSourceTime:),
                     (IMP)LPProbeStartSession, (IMP *)&gPStartSession);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LPProbeSweep(); });

    LPLog(@"[probe] BẬT — mở camera, quay thử, rồi gửi log.txt");
}
