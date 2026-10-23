// ============================================================================
//  LPProbe.m — v6.3: CHỈ ĐỌC, KHÔNG ĐỤNG CAPTURE SESSION
//
//  Bản trước hook AVCaptureSession addInput:/addOutput:/canAddInput: — đó là
//  can thiệp vào đúng lúc Locket đang dựng session, và app chết ngay sau
//  dòng log addOutput. Dù chưa chứng minh được hook gây chết, không đáng
//  giữ lại: nó không cần thiết để tìm ra giới hạn 15 giây.
//
//  Bản này chỉ hook AVAssetWriter — nơi Locket THẬT SỰ ghi file. Đọc được:
//    • fileType, URL
//    • startSessionAtSourceTime: (mốc bắt đầu)
//    • endSessionAtSourceTime:   ← NẾU có, đây chính là chỗ đặt 15 giây
//    • finishWritingWithCompletionHandler: (thời điểm kết thúc)
//
//  Nếu Locket gọi endSessionAtSourceTime: với 15.0 thì ta biết chính xác
//  giới hạn nằm ở đó. Nếu không, nó là timer bên ngoài.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static BOOL gProbeOn = NO;

#define PROBE(fmt, ...) do { if (gProbeOn) LPLog(@"[probe] " fmt, ##__VA_ARGS__); } while (0)

static NSTimeInterval gWriterStart = 0;
static NSTimeInterval gSessionStart = 0;

#pragma mark - AVAssetWriter

static id (*gPWriterInit)(id, SEL, NSURL *, NSString *, NSError **);
static id LPProbeWriterInit(id self, SEL _cmd, NSURL *url, NSString *type, NSError **err) {
    id r = gPWriterInit
        ? ((id (*)(id, SEL, NSURL *, NSString *, NSError **))gPWriterInit)(self, _cmd, url, type, err)
        : nil;
    gWriterStart = [NSDate timeIntervalSinceReferenceDate];
    PROBE("AVAssetWriter init fileType=%@ ok=%d", type, r != nil);
    return r;
}

static BOOL (*gPStartSession)(id, SEL, CMTime);
static BOOL LPProbeStartSession(id self, SEL _cmd, CMTime t) {
    BOOL r = gPStartSession ? ((BOOL (*)(id, SEL, CMTime))gPStartSession)(self, _cmd, t) : NO;
    gSessionStart = [NSDate timeIntervalSinceReferenceDate];
    PROBE("startSessionAtSourceTime: %.3fs → %d", CMTimeGetSeconds(t), r);
    return r;
}

// ĐÂY LÀ CHỖ QUAN TRỌNG NHẤT.
// Nếu Locket gọi hàm này thì nó đang đặt mốc kết thúc cố định — chính là
// giới hạn 15 giây. Ghi lại giá trị để biết chắc.
static void (*gPEndSession)(id, SEL, CMTime);
static void LPProbeEndSession(id self, SEL _cmd, CMTime t) {
    double s = CMTimeGetSeconds(t);
    NSTimeInterval el = gSessionStart > 0
        ? [NSDate timeIntervalSinceReferenceDate] - gSessionStart : -1;
    PROBE("endSessionAtSourceTime: %.3fs (đã ghi %.2fs) ← 15s ở đây là GIỚI HẠN CỨNG",
          s, el);
    if (gPEndSession) ((void (*)(id, SEL, CMTime))gPEndSession)(self, _cmd, t);
}

static void (*gPFinish)(id, SEL, void (^)(void));
static void LPProbeFinish(id self, SEL _cmd, void (^handler)(void)) {
    NSTimeInterval el = gWriterStart > 0
        ? [NSDate timeIntervalSinceReferenceDate] - gWriterStart : -1;
    PROBE("finishWriting sau %.2fs", el);
    if (gPFinish) ((void (*)(id, SEL, void (^)(void)))gPFinish)(self, _cmd, handler);
}

#pragma mark - AVAssetWriterInput: xem có audio track không

static id (*gPInputInit)(id, SEL, NSString *, NSDictionary *);
static id LPProbeInputInit(id self, SEL _cmd, NSString *type, NSDictionary *outputSettings) {
    id r = gPInputInit
        ? ((id (*)(id, SEL, NSString *, NSDictionary *))gPInputInit)(self, _cmd, type, outputSettings)
        : nil;
    PROBE("AVAssetWriterInput mediaType=%@ ok=%d", type, r != nil);
    return r;
}

#pragma mark - install

void LPInstallProbe(void) {
    gProbeOn = [[LPConfig shared] flag:@"probeEnabled" fallback:NO];
    if (!gProbeOn) return;

    Class w = NSClassFromString(@"AVAssetWriter");
    if (w) {
        LPHookMethod(w, @selector(initWithURL:fileType:error:),
                     (IMP)LPProbeWriterInit, (IMP *)&gPWriterInit);
        LPHookMethod(w, @selector(startSessionAtSourceTime:),
                     (IMP)LPProbeStartSession, (IMP *)&gPStartSession);
        LPHookMethod(w, @selector(endSessionAtSourceTime:),
                     (IMP)LPProbeEndSession, (IMP *)&gPEndSession);
        LPHookMethod(w, @selector(finishWritingWithCompletionHandler:),
                     (IMP)LPProbeFinish, (IMP *)&gPFinish);
    }

    Class wi = NSClassFromString(@"AVAssetWriterInput");
    if (wi) {
        LPHookMethod(wi, @selector(initWithMediaType:outputSettings:),
                     (IMP)LPProbeInputInit, (IMP *)&gPInputInit);
    }

    LPLog(@"[probe] BẬT (chỉ AVAssetWriter) — quay thử 20s rồi gửi log.txt");
}
