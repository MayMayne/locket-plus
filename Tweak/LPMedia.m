#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static BOOL gVideoHooksInstalled = NO;

#pragma mark - helpers

static void LPHook(Class cls, SEL sel, IMP newImp) {
    if (!cls) { LPLog(@"[media] không có class cho %@", NSStringFromSelector(sel)); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { LPLog(@"[media] thiếu method %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel)); return; }
    IMP orig = method_getImplementation(m);
    LPSetOrigIMP(cls, sel, orig);
    method_setImplementation(m, newImp);
    LPLog(@"[media] hook %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

#pragma mark - AVFoundation: thời lượng / dung lượng

// AVCaptureMovieFileOutput: app đặt trần quay phim
static void LPMovieMaxDurationSet(id self, SEL _cmd, CMTime t) {
    double secs = CMTimeGetSeconds(t);
    if (secs > 0 && !isnan(secs)) LPLog(@"[media] maxRecordedDuration thật = %.1fs -> ép %.0fs", secs, LPVideoSeconds());
    CMTime forced = CMTimeMakeWithSeconds(LPVideoSeconds(), 600);
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, CMTime))o)(self, _cmd, forced);
}

static void LPMovieMaxSizeSet(id self, SEL _cmd, long long size) {
    LPLog(@"[media] maxRecordedFileSize thật = %lld bytes -> ép %.0f", size, LPVideoBytes());
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, long long))o)(self, _cmd, (long long)LPVideoBytes());
}

// UIImagePickerController (chọn video từ thư viện)
static void LPPickerMaxDurSet(id self, SEL _cmd, double secs) {
    LPLog(@"[media] videoMaximumDuration thật = %.1fs -> ép %.0fs", secs, LPVideoSeconds());
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, double))o)(self, _cmd, LPVideoSeconds());
}

// AVAssetExportSession: mở lại timeRange nếu app cắt
static void LPExportTimeRangeSet(id self, SEL _cmd, CMTimeRange r) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (![[LPConfig shared] flag:@"widenExportRange" fallback:YES] || !o) {
        if (o) ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, r);
        return;
    }
    AVAsset *asset = nil;
    @try { asset = [self valueForKey:@"asset"]; } @catch (__unused NSException *e) {}
    if (asset && CMTIME_IS_VALID(asset.duration)) {
        double full = CMTimeGetSeconds(asset.duration);
        double end = CMTimeGetSeconds(CMTimeRangeGetEnd(r));
        if (full > 0 && end < full - 0.05) {
            LPLog(@"[media] export range 0→%.2fs của asset %.2fs -> mở full", end, full);
            ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, CMTimeRangeMake(kCMTimeZero, asset.duration));
            return;
        }
    }
    ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, r);
}

// AVAsset.duration: báo ngắn hơn để UI/validator cho qua
static CMTime LPDurationGet(id self, SEL _cmd) {
    IMP o = LPOrigIMPFor(self, _cmd);
    CMTime d = o ? ((CMTime (*)(id, SEL))o)(self, _cmd) : kCMTimeZero;
    if (![[LPConfig shared] flag:@"clampReportedDuration" fallback:YES]) return d;
    double secs = CMTimeGetSeconds(d);
    if (secs > LPVideoSeconds()) {
        LPLog(@"[media] %@.duration %.1fs -> báo %.1fs", NSStringFromClass([self class]), secs, LPVideoSeconds());
        return CMTimeMakeWithSeconds(LPVideoSeconds(), 600);
    }
    return d;
}

// NSURL.duration trên file .mov/.mp4 cũng có thể bị kiểm
static NSDictionary *LPFileAttributes(id self, SEL _cmd, NSString *path, NSError **err) {
    IMP o = LPOrigIMPFor(self, _cmd);
    NSDictionary *d = o ? ((NSDictionary *(*)(id, SEL, NSString *, NSError **))o)(self, _cmd, path, err) : nil;
    if (!d || ![[LPConfig shared] flag:@"clampReportedSize" fallback:YES]) return d;
    NSNumber *sz = d[NSFileSize];
    if (sz && sz.doubleValue > LPVideoBytes()) {
        NSMutableDictionary *m = [d mutableCopy];
        m[NSFileSize] = @((long long)LPVideoBytes());
        LPLog(@"[media] %@ %.1fMB -> báo %.0fMB", path.lastPathComponent, sz.doubleValue / 1048576.0,
              LPVideoBytes() / 1048576.0);
        return m;
    }
    return d;
}

static BOOL LPGetResourceValue(id self, SEL _cmd, id *out, NSString *key, NSError **err) {
    IMP o = LPOrigIMPFor(self, _cmd);
    BOOL ok = o ? ((BOOL (*)(id, SEL, id *, NSString *, NSError **))o)(self, _cmd, out, key, err) : NO;
    if (ok && out && [key isEqualToString:NSURLFileSizeKey] &&
        [[LPConfig shared] flag:@"clampReportedSize" fallback:YES]) {
        NSNumber *sz = (NSNumber *)*out;
        if ([sz isKindOfClass:[NSNumber class]] && sz.doubleValue > LPVideoBytes()) {
            LPLog(@"[media] NSURLFileSize %.1fMB -> báo %.0fMB", sz.doubleValue / 1048576.0,
                  LPVideoBytes() / 1048576.0);
            *out = @((long long)LPVideoBytes());
        }
    }
    return ok;
}

#pragma mark - đo dung lượng upload

static id LPUploadData(id self, SEL _cmd, NSURLRequest *req, NSData *body, id completion) {
    LPLog(@"[net] upload %@ %ld bytes", req.URL.path, (long)body.length);
    IMP o = LPOrigIMPFor(self, _cmd);
    return o ? ((id (*)(id, SEL, NSURLRequest *, NSData *, id))o)(self, _cmd, req, body, completion) : nil;
}

static id LPUploadFile(id self, SEL _cmd, NSURLRequest *req, NSURL *file, id completion) {
    NSNumber *sz = nil;
    [file getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
    LPLog(@"[net] uploadFile %@ %@ bytes", req.URL.path, sz ?: @"?");
    IMP o = LPOrigIMPFor(self, _cmd);
    return o ? ((id (*)(id, SEL, NSURLRequest *, NSURL *, id))o)(self, _cmd, req, file, completion) : nil;
}

#pragma mark - install

void LPInstallMediaHooks(void) {
    if (gVideoHooksInstalled) return;
    gVideoHooksInstalled = YES;

    // Chỉ hook đúng 2 hàm đặt trần quay phim. Không đụng NSURLSession,
    // AVAsset, NSFileManager hay NSURL — hook nhầm hàm hệ thống gọi hàng
    // nghìn lần/giây là nguyên nhân làm app chết ngay khi mở.
    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    LPHook(out, @selector(setMaxRecordedDuration:), (IMP)LPMovieMaxDurationSet);
    LPHook(out, @selector(setMaxRecordedFileSize:), (IMP)LPMovieMaxSizeSet);

    LPLog(@"[media] cấu hình %.0fs / %.0fMB", LPVideoSeconds(), LPVideoBytes() / 1048576.0);
}
