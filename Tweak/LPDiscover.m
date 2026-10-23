// ============================================================================
//  LPDiscover.m — DÒ CLASS THẬT CỦA LOCKET LÚC CHẠY (không cần binary)
//
//  Ý tưởng: log trước đã chứng minh Locket dùng AVCaptureVideoDataOutput.
//  Output đó PHẢI có một delegate — và delegate chính là class ghi video của
//  Locket. Hook setSampleBufferDelegate:queue: để lấy tên class đó, rồi dump
//  toàn bộ ivar + method của nó và của chuỗi class cha.
//
//  Từ danh sách đó sẽ thấy:
//    • tên class Swift thật (ví dụ _TtC11JournalFeature...Recorder)
//    • ivar kiểu `maximumDuration`, `durationLimit`, `maxRecordingTime`…
//    • method `stopRecording`, `handleTimer`, `finishClip`…
//
//  CHỈ ĐỌC. Không sửa tham số, không đổi graph session, không gọi audio.
//  Mọi hook đều gọi IMP gốc y nguyên.
//
//  Cũng hook NSTimer để bắt timer 15 giây — nếu Locket dùng timer thì đây là
//  bằng chứng trực tiếp.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL gOn = NO;
static NSMutableSet<NSString *> *gDumped;

#define D(fmt, ...) do { if (gOn) LPLog(@"[discover] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - dump một class

static void LPDumpClass(Class c, int maxMethods) {
    if (!c) return;
    NSString *name = NSStringFromClass(c);
    if (!name.length) return;

    @synchronized (gDumped) {
        if ([gDumped containsObject:name]) return;
        [gDumped addObject:name];
    }

    D("=== CLASS %s (super=%s)", class_getName(c),
      class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "nil");

    // IVAR — Swift stored property hiện ra ở đây với tên mangled.
    // Đây là chỗ dễ thấy `maximumDuration` / `durationLimit` nhất.
    unsigned int n = 0;
    Ivar *ivars = class_copyIvarList(c, &n);
    for (unsigned i = 0; i < n && i < 40; i++) {
        const char *in = ivar_getName(ivars[i]);
        const char *it = ivar_getTypeEncoding(ivars[i]);
        D("  ivar %s : %s", in ?: "?", it ?: "?");
    }
    if (ivars) free(ivars);

    // METHOD — chỉ của class này, không đi lên cha.
    n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n && (int)i < maxMethods; i++) {
        D("  meth %s", sel_getName(method_getName(ms[i])));
    }
    if (ms) free(ms);

    if (n > (unsigned)maxMethods) D("  ... còn %u method nữa", n - (unsigned)maxMethods);
}

#pragma mark - bắt delegate của video data output

static void (*gPSetDelegate)(id, SEL, id, dispatch_queue_t);

static void LPDiscoverSetDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t q) {
    if (gPSetDelegate) ((void (*)(id, SEL, id, dispatch_queue_t))gPSetDelegate)(self, _cmd, delegate, q);

    if (!delegate) return;
    Class c = object_getClass(delegate);
    D("videoDataOutput delegate = %s", class_getName(c));

    // Dump class delegate + 3 cấp cha.
    Class cur = c;
    for (int i = 0; i < 4 && cur; i++) {
        LPDumpClass(cur, 60);
        cur = class_getSuperclass(cur);
    }
}

#pragma mark - bắt timer 15 giây

static NSTimer *(*gPSchedBlock)(id, SEL, NSTimeInterval, BOOL, void (^)(NSTimer *));
static NSTimer *LPDiscoverSchedBlock(id self, SEL _cmd, NSTimeInterval ti, BOOL repeats,
                                     void (^block)(NSTimer *)) {
    if (ti >= 8.0 && ti <= 25.0) {
        D("NSTimer block %.2fs repeats=%d", ti, repeats);
        // In ngăn xếp để biết ai tạo timer này.
        NSArray *st = [NSThread callStackSymbols];
        for (NSUInteger i = 1; i < st.count && i < 12; i++) D("    %@", st[i]);
    }
    return gPSchedBlock
        ? ((NSTimer *(*)(id, SEL, NSTimeInterval, BOOL, void (^)(NSTimer *)))gPSchedBlock)
            (self, _cmd, ti, repeats, block)
        : nil;
}

static NSTimer *(*gPSchedTarget)(id, SEL, NSTimeInterval, id, SEL, id, BOOL);
static NSTimer *LPDiscoverSchedTarget(id self, SEL _cmd, NSTimeInterval ti, id target,
                                      SEL sel, id info, BOOL repeats) {
    if (ti >= 8.0 && ti <= 25.0) {
        D("NSTimer target %.2fs sel=%s repeats=%d", ti, sel_getName(sel), repeats);
        NSArray *st = [NSThread callStackSymbols];
        for (NSUInteger i = 1; i < st.count && i < 12; i++) D("    %@", st[i]);
    }
    return gPSchedTarget
        ? ((NSTimer *(*)(id, SEL, NSTimeInterval, id, SEL, id, BOOL))gPSchedTarget)
            (self, _cmd, ti, target, sel, info, repeats)
        : nil;
}

#pragma mark - liệt kê class của app

static void LPSweepAppClasses(void) {
    static const char *keys[] = {
        "Record", "Video", "Capture", "Camera", "Movie", "Clip",
        "Moment", "Writer", "Composer", "Export"
    };

    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return;
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (!all) return;
    total = objc_getClassList(all, total);

    int shown = 0;
    for (int i = 0; i < total && shown < 80; i++) {
        const char *n = class_getName(all[i]);
        if (!n) continue;

        // Chỉ class của app: bundle image chứa ".app/" hoặc tên có _TtC (Swift).
        BOOL swift = (strncmp(n, "_TtC", 4) == 0 || strncmp(n, "_TtP", 4) == 0);
        if (!swift) continue;

        for (size_t k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
            if (strstr(n, keys[k])) {
                D("app class: %s", n);
                shown++;
                break;
            }
        }
    }
    free(all);
    D("quét xong: %d class khớp", shown);
}

#pragma mark - install

void LPInstallDiscover(void) {
    gOn = [[LPConfig shared] flag:@"discoverEnabled" fallback:NO];
    if (!gOn) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{ gDumped = [NSMutableSet set]; });

    Class vdo = NSClassFromString(@"AVCaptureVideoDataOutput");
    if (vdo) {
        LPHookMethod(vdo, @selector(setSampleBufferDelegate:queue:),
                     (IMP)LPDiscoverSetDelegate, (IMP *)&gPSetDelegate);
        D("hook setSampleBufferDelegate:queue: = %d", gPSetDelegate != NULL);
    }

    Class timer = NSClassFromString(@"NSTimer");
    if (timer) {
        LPHookMethod(timer, @selector(scheduledTimerWithTimeInterval:repeats:block:),
                     (IMP)LPDiscoverSchedBlock, (IMP *)&gPSchedBlock);
        LPHookMethod(timer,
                     @selector(scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:),
                     (IMP)LPDiscoverSchedTarget, (IMP *)&gPSchedTarget);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LPSweepAppClasses(); });

    LPLog(@"[discover] BẬT — mở camera, quay 20s, rồi gửi log.txt");
}
