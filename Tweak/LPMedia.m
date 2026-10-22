// ============================================================================
//  LocketPlus.dylib — CHỈ 2 SETTER
//
//  4 dylib mẫu đã làm hết phần còn lại:
//    blatantsPatch.dylib   → sideload (app group + keychain)
//    AutoRcSideload.dylib  → Gold (rewrite JSON RevenueCat)
//    MHVideoPipeline.dylib → nén video cho vừa upload (6MB)
//    MHProfileVideo.dylib  → video bìa profile
//
//  Chúng chạy cùng nhau KHÔNG crash. Nếu mình viết lại những thứ đó thì
//  hook trùng → crash. Nên dylib này KHÔNG đụng gì tới chúng.
//
//  Thứ duy nhất 4 mẫu KHÔNG làm: nâng trần quay.
//  MHVideoPipeline chỉ NÉN (setFileLengthLimit 6MB), không nâng
//  maxRecordedDuration / maxRecordedFileSize. Đó chính là 2 setter dưới đây.
//
//  ABI: CMTime 24 byte truyền làm THAM SỐ → compiler tự lo, an toàn.
//  KHÔNG hook getter trả struct (struct >16 byte trả qua con trỏ ẩn x8).
// ============================================================================

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

#define LP_LOG(fmt, ...) NSLog(@"[LocketPlus] " fmt, ##__VA_ARGS__)

#pragma mark - cấu hình (đọc 1 lần, không hook gì)

static double gSeconds = 600.0;
static long long gBytes = 500LL * 1024 * 1024;

static void LPLoadConfig(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    if (!docs.length) return;
    NSString *dir = [docs stringByAppendingPathComponent:@"LocketPlus"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *p = [dir stringByAppendingPathComponent:@"config.plist"];

    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    if (![d isKindOfClass:[NSDictionary class]]) {
        d = @{ @"maxVideoSeconds": @600,
               @"maxVideoBytes": @(500.0 * 1024 * 1024) };
        [d writeToFile:p atomically:YES];
    }

    id s = d[@"maxVideoSeconds"];
    if ([s respondsToSelector:@selector(doubleValue)]) {
        double v = [s doubleValue];
        if (v >= 10.0 && v <= 3600.0) gSeconds = v;
    }
    id b = d[@"maxVideoBytes"];
    if ([b respondsToSelector:@selector(doubleValue)]) {
        double v = [b doubleValue];
        if (v >= 5.0 * 1024 * 1024 && v <= 4096.0 * 1024 * 1024) gBytes = (long long)v;
    }
    LP_LOG(@"cấu hình: %.0fs / %.0fMB", gSeconds, gBytes / 1048576.0);
}

#pragma mark - IMP gốc

// Kỹ thuật giống _Hook @0x8364 (MHVideoPipeline) / _ObserveMethod @0x4570
// (blatantsPatch): duyệt class_copyMethodList để biết class SỞ HỮU method.
// KHÔNG dùng class_getInstanceMethod — nó đi lên class cha, và
// method_setImplementation khi đó sẽ sửa Method của CHA (ảnh hưởng mọi subclass).
static IMP gOrigDuration = NULL;
static IMP gOrigFileSize = NULL;

static Method LPOwned(Class cls, SEL sel, Class *ownerOut) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        if (!list) continue;
        Method found = NULL;
        for (unsigned i = 0; i < n; i++) {
            if (method_getName(list[i]) == sel) { found = list[i]; break; }
        }
        free(list);
        if (found) { if (ownerOut) *ownerOut = c; return found; }
    }
    return NULL;
}

static BOOL LPHook(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Class owner = Nil;
    Method m = LPOwned(cls, sel, &owner);
    if (!m) return NO;

    IMP orig = method_getImplementation(m);
    if (orig == newImp) return YES;          // đã hook rồi

    if (origOut) *origOut = orig;

    if (owner == cls) {
        method_setImplementation(m, newImp);
        return YES;
    }
    // Method thừa kế → thêm bản riêng cho class đích, class cha không bị đụng.
    const char *types = method_getTypeEncoding(m);
    if (types && class_addMethod(cls, sel, newImp, types)) return YES;
    method_setImplementation(m, newImp);
    return YES;
}

#pragma mark - 2 setter

static void LPSetMaxDuration(id self, SEL _cmd, CMTime t) {
    double real = CMTimeGetSeconds(t);
    if (isfinite(real) && real > 0 && real < gSeconds) {
        LP_LOG(@"maxRecordedDuration %.0fs → %.0fs", real, gSeconds);
    }
    if (gOrigDuration) {
        ((void (*)(id, SEL, CMTime))gOrigDuration)(self, _cmd,
                                                   CMTimeMakeWithSeconds(gSeconds, 600));
    }
}

static void LPSetMaxFileSize(id self, SEL _cmd, long long size) {
    if (size > 0 && size < gBytes) {
        LP_LOG(@"maxRecordedFileSize %lld → %lld", size, gBytes);
    }
    if (gOrigFileSize) {
        ((void (*)(id, SEL, long long))gOrigFileSize)(self, _cmd, gBytes);
    }
}

#pragma mark - install

static void LPInstall(void) {
    LPLoadConfig();

    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    if (!out) {
        LP_LOG(@"KHÔNG có AVCaptureMovieFileOutput — không hook được");
        return;
    }

    BOOL a = LPHook(out, @selector(setMaxRecordedDuration:), (IMP)LPSetMaxDuration, &gOrigDuration);
    BOOL b = LPHook(out, @selector(setMaxRecordedFileSize:), (IMP)LPSetMaxFileSize, &gOrigFileSize);

    LP_LOG(@"hook duration=%d size=%d → %.0fs / %.0fMB",
           a, b, gSeconds, gBytes / 1048576.0);
}

__attribute__((constructor))
static void LPInit(void) {
    @autoreleasepool {
        // Chờ main queue: AVFoundation chắc chắn đã nạp, và không đụng gì
        // trong constructor (dylib nạp trước khi UIApplication tồn tại).
        dispatch_async(dispatch_get_main_queue(), ^{
            @try { LPInstall(); }
            @catch (NSException *e) { LP_LOG(@"lỗi: %@", e.reason); }
        });
    }
}
