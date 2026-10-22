// ============================================================================
//  LPCommon.m — cấu hình, log thread-safe, hook an toàn, tầng mạng dùng chung
// ============================================================================

#import "LPCommon.h"
#import <objc/message.h>
#import <sys/stat.h>
#import <stdarg.h>

static LPConfig *gConfig;

#pragma mark - LPConfig

@implementation LPConfig

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gConfig = [LPConfig new];
        [gConfig reload];
    });
    return gConfig;
}

- (void)reload {
    NSString *p = LPPath(@"config.plist");
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSDictionary *def = @{
            @"safeMode"            : @NO,
            @"goldEnabled"         : @YES,
            @"mediaEnabled"        : @YES,
            @"sideloadFix"         : @YES,
            @"maxRecordSeconds"    : @600,
            @"maxRecordBytes"      : @(500.0 * 1024 * 1024),
            @"maxUploadSeconds"    : @60,
            @"maxUploadBytes"      : @(15.0 * 1024 * 1024),
            @"addMicInput"         : @YES,
            @"keepAudioSession"    : @YES,
            @"frameRatioEnabled"   : @YES,
            @"frameRatioDefault"   : @"auto",
            @"logVerbose"          : @YES
        };
        [def writeToFile:p atomically:YES];
    }
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
    self.plist = [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

- (BOOL)flag:(NSString *)key fallback:(BOOL)fb {
    id v = self.plist[key];
    return v ? [v boolValue] : fb;
}
- (double)dbl:(NSString *)key fallback:(double)fb {
    id v = self.plist[key];
    return v ? [v doubleValue] : fb;
}
- (NSString *)str:(NSString *)key fallback:(NSString *)fb {
    id v = self.plist[key];
    return [v isKindOfClass:[NSString class]] ? v : fb;
}
- (id)obj:(NSString *)key { return key ? self.plist[key] : nil; }

// Ghi log có khoá. Hook chạy trên main / network / capture thread cùng lúc;
// ghi file không khoá là crash (đúng lỗi v1.13).
+ (void)log:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!msg.length) return;

    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });

    [lock lock];
    @try {
        NSString *p = LPPath(@"log.txt");
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) {
            [d writeToFile:p atomically:YES];
        } else {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:d];
                [fh closeFile];
            } @catch (__unused NSException *e) {}
        }
        struct stat st;
        if (stat([p fileSystemRepresentation], &st) == 0 && st.st_size > 384 * 1024) {
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        }
    } @catch (__unused NSException *e) {}
    [lock unlock];
}

+ (NSString *)logText {
    return [NSString stringWithContentsOfFile:LPPath(@"log.txt")
                                     encoding:NSUTF8StringEncoding error:nil] ?: @"(log trống)";
}

@end

#pragma mark - đường dẫn

NSString *LPDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES).firstObject;
        if (!d.length) d = NSTemporaryDirectory();
        dir = [d stringByAppendingPathComponent:@"LocketPlus"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

NSString *LPPath(NSString *name) {
    return [LPDir() stringByAppendingPathComponent:name ?: @""];
}

// blatantsPatch dựng thư mục thay thế cho app group dưới
// <ApplicationSupport>/../Shared/AppGroup/<groupID> — tức <container>/Library/Shared/AppGroup/…
// Đường dẫn phải ỔN ĐỊNH giữa các lần chạy, nếu đổi thì dữ liệu cũ mất.
NSString *LPGroupPathFor(NSString *groupID) {
    if (![groupID isKindOfClass:[NSString class]] || !groupID.length) return nil;
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject;
    if (!base.length) base = NSTemporaryDirectory();
    NSString *shared = [[base stringByAppendingPathComponent:@"../Shared/AppGroup"]
                        stringByStandardizingPath];
    NSString *dir = [shared stringByAppendingPathComponent:groupID];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

#pragma mark - giới hạn

BOOL LPSafeMode(void) {
    return [[LPConfig shared] flag:@"safeMode" fallback:NO];
}
void LPSetSafeMode(BOOL on) {
    NSMutableDictionary *m = [[[LPConfig shared] plist] mutableCopy] ?: [NSMutableDictionary dictionary];
    m[@"safeMode"] = @(on);
    [m writeToFile:LPPath(@"config.plist") atomically:YES];
    [[LPConfig shared] reload];
    LPLog(@"[boot] safeMode = %d", on);
}

static double LPClamp(double v, double lo, double hi) {
    if (!isfinite(v)) return lo;
    return MAX(lo, MIN(v, hi));
}

// Trần QUAY (ghi hình) — mặc định 600s / 500MB theo yêu cầu.
double LPMaxRecordSeconds(void) {
    return LPClamp([[LPConfig shared] dbl:@"maxRecordSeconds" fallback:600.0], 10.0, 3600.0);
}
double LPMaxRecordBytes(void) {
    return LPClamp([[LPConfig shared] dbl:@"maxRecordBytes" fallback:500.0 * 1024 * 1024],
                   5.0 * 1024 * 1024, 4096.0 * 1024 * 1024);
}
// Trần UPLOAD (chọn từ thư viện) — mặc định 60s / 15MB theo yêu cầu.
double LPUploadSeconds(void) {
    return LPClamp([[LPConfig shared] dbl:@"maxUploadSeconds" fallback:60.0], 5.0, 3600.0);
}
double LPUploadBytes(void) {
    return LPClamp([[LPConfig shared] dbl:@"maxUploadBytes" fallback:15.0 * 1024 * 1024],
                   1.0 * 1024 * 1024, 4096.0 * 1024 * 1024);
}

#pragma mark - bảng IMP gốc

static NSMutableDictionary<NSString *, NSValue *> *gIMPTable;
static NSLock *gIMPLock;

static void LPIMPInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gIMPTable = [NSMutableDictionary dictionary];
        gIMPLock = [NSLock new];
    });
}

static NSString *LPKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}

static void LPSetOrig(Class cls, SEL sel, IMP imp) {
    LPIMPInit();
    [gIMPLock lock];
    gIMPTable[LPKey(cls, sel)] = [NSValue valueWithPointer:imp];
    [gIMPLock unlock];
}

IMP LPOrigIMPFor(id self, SEL sel) {
    if (!self || !sel) return NULL;
    LPIMPInit();
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        [gIMPLock lock];
        NSValue *v = gIMPTable[LPKey(c, sel)];
        [gIMPLock unlock];
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}

#pragma mark - hook an toàn

// Tìm class SỞ HỮU method — đúng kỹ thuật _Hook @0x8364 (MHVideoPipeline) và
// _ObserveMethod @0x4570 (blatantsPatch).
//
// SAI: class_getInstanceMethod(cls, sel) đi lên class cha khi cls không tự cài,
// rồi method_setImplementation sửa Method của CHA → mọi subclass đổi theo.
// Ví dụ hook -[NSURLSession dataTaskWithRequest:] khi method thật nằm ở
// __NSCFURLSession: mọi session trong app (kể cả hệ thống) chạy qua code ta.
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

BOOL LPHookMethod(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;

    Class owner = Nil;
    Method m = LPOwned(cls, sel, &owner);
    if (!m) return NO;

    IMP orig = method_getImplementation(m);
    if (orig == newImp) return YES;              // đã hook

    if (owner == cls) {
        LPSetOrig(cls, sel, orig);
        method_setImplementation(m, newImp);
        if (origOut) *origOut = orig;
        return YES;
    }

    // Method thừa kế: thêm bản riêng cho class đích. Class cha KHÔNG bị đụng.
    const char *types = method_getTypeEncoding(m);
    if (types && class_addMethod(cls, sel, newImp, types)) {
        LPSetOrig(cls, sel, orig);
        if (origOut) *origOut = orig;
        return YES;
    }
    // class_addMethod thất bại (đã có bản riêng do race) → sửa tại chỗ.
    LPSetOrig(cls, sel, orig);
    method_setImplementation(m, newImp);
    if (origOut) *origOut = orig;
    return YES;
}

BOOL LPHookMethodTyped(Class cls, SEL sel, const char *expectReturn,
                       IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Method m = LPOwned(cls, sel, NULL);
    if (!m) return NO;
    const char *types = method_getTypeEncoding(m);
    if (!types || !expectReturn) return NO;
    if (types[0] != expectReturn[0]) {
        LPLog(@"[hook] bỏ qua %s %s: kiểu trả '%c' ≠ '%c'",
              class_getName(cls), sel_getName(sel), types[0], expectReturn[0]);
        return NO;
    }
    return LPHookMethod(cls, sel, newImp, origOut);
}

// Chờ class nạp muộn (Swift class của Locket, RevenueCat…). Tối đa 20s,
// kiểm mỗi 250ms trên main queue. Block chạy ĐÚNG 1 lần.
void LPWhenClassReady(NSString *name, void (^block)(Class cls)) {
    if (!name.length || !block) return;

    __block BOOL done = NO;
    __block int tries = 0;

    void (^poll)(void) = ^{
        if (done) return;
        Class c = NSClassFromString(name);
        if (c) { done = YES; @try { block(c); } @catch (NSException *e) {
            LPLog(@"[hook] block %@ lỗi: %@", name, e.reason); } return; }
        if (++tries > 80) return;                 // 80 × 250ms = 20s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), poll);
    };
    dispatch_async(dispatch_get_main_queue(), poll);
}

#pragma mark - tầng mạng dùng chung

@implementation LPNetResult
@end

static NSMutableArray<LPNetProcessor> *gProcessors;
static NSLock *gProcLock;

void LPAddNetProcessor(LPNetProcessor p) {
    if (!p) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gProcessors = [NSMutableArray array];
        gProcLock = [NSLock new];
    });
    [gProcLock lock];
    [gProcessors addObject:[p copy]];
    [gProcLock unlock];
}

static void LPRunProcessors(NSURLRequest *req, LPNetResult *res) {
    if (!req || !res) return;
    NSArray *snapshot;
    [gProcLock lock];
    snapshot = [gProcessors copy];
    [gProcLock unlock];
    for (LPNetProcessor p in snapshot) {
        @try { p(req, res); }
        @catch (NSException *e) { LPLog(@"[net] processor lỗi: %@", e.reason); }
    }
}

// Hook completion-handler của NSURLSession. Class cluster: method thật nằm ở
// __NSCFURLSession, nên hook cả base lẫn concrete (class_addMethod lên base).
typedef void (^LPCompletion)(NSData *, NSURLResponse *, NSError *);

// Trả về id (NSURLSessionDataTask *) — KHÔNG được khai báo void.
// Caller dùng giá trị trả về để -resume; bỏ mất là task không bao giờ chạy.
// Lấy IMP gốc qua LPOrigIMPFor(self, _cmd) chứ không qua biến toàn cục: khi
// hook cả base lẫn concrete, biến toàn cục sẽ bị ghi đè bởi lớp sau.
static id LPDataTaskReq(id self, SEL _cmd, NSURLRequest *req, LPCompletion handler) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    if (!handler || !req) {
        return ((id (*)(id, SEL, NSURLRequest *, LPCompletion))o)(self, _cmd, req, handler);
    }
    NSURLRequest *captured = req;
    LPCompletion wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        LPNetResult *r = [LPNetResult new];
        r.data = data;
        r.response = resp;
        LPRunProcessors(captured, r);
        handler(r.data, r.response, err);
    };
    return ((id (*)(id, SEL, NSURLRequest *, LPCompletion))o)(self, _cmd, req, wrapped);
}

static id LPDataTaskURL(id self, SEL _cmd, NSURL *url, LPCompletion handler) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    if (!handler || !url) {
        return ((id (*)(id, SEL, NSURL *, LPCompletion))o)(self, _cmd, url, handler);
    }
    NSURLRequest *captured = [NSURLRequest requestWithURL:url];
    LPCompletion wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        LPNetResult *r = [LPNetResult new];
        r.data = data;
        r.response = resp;
        LPRunProcessors(captured, r);
        handler(r.data, r.response, err);
    };
    return ((id (*)(id, SEL, NSURL *, LPCompletion))o)(self, _cmd, url, wrapped);
}

static BOOL gNetInstalled = NO;

void LPInstallNetHooks(void) {
    if (gNetInstalled) return;
    gNetInstalled = YES;

    // Quét 3 lần vì Firebase/RevenueCat tạo session muộn.
    for (int round = 0; round < 3; round++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(round * 2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class base = NSClassFromString(@"NSURLSession");
            Class concrete = NSClassFromString(@"__NSCFURLSession");
            SEL s1 = @selector(dataTaskWithRequest:completionHandler:);
            SEL s2 = @selector(dataTaskWithURL:completionHandler:);

            if (base) {
                LPHookMethod(base, s1, (IMP)LPDataTaskReq, NULL);
                LPHookMethod(base, s2, (IMP)LPDataTaskURL, NULL);
            }
            if (concrete && concrete != base) {
                LPHookMethod(concrete, s1, (IMP)LPDataTaskReq, NULL);
                LPHookMethod(concrete, s2, (IMP)LPDataTaskURL, NULL);
            }
            LPLog(@"[net] hook NSURLSession vòng %d (base=%p concrete=%p)",
                  round, base, concrete);
        });
    }
}
