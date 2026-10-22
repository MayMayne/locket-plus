// ============================================================================
//  LPCommon.m — cấu hình, log, hook an toàn, tầng mạng dùng chung
// ============================================================================

#import "LPCommon.h"
#import <objc/message.h>
#import <sys/stat.h>

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

+ (NSString *)dir { return LPDir(); }
+ (NSString *)path:(NSString *)name { return LPPath(name); }

- (void)reload {
    NSString *p = LPPath(@"config.plist");
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSDictionary *def = @{
            @"maxVideoSeconds"      : @600,
            @"maxVideoBytes"        : @(500.0 * 1024 * 1024),
            @"keepMicOnRecord"      : @YES,
            @"addMicInput"          : @YES,
            @"goldUnlock"           : @YES,
            @"friendLimitUnlock"    : @YES,
            @"friendDiagnostics"    : @YES,
            @"autoRefreshOnAuthFail": @YES,
            @"safeMode"             : @NO,
            @"logVerbose"           : @NO
        };
        [def writeToFile:p atomically:YES];
    }
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:p];
    self.plist = [loaded isKindOfClass:[NSDictionary class]] ? loaded : @{};
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

// Ghi log thread-safe. Hook chạy trên network/main/capture thread cùng lúc —
// ghi file không khoá là crash (đúng lỗi đã gặp ở v1.13).
+ (void)log:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!msg) return;

    static NSLock *lock;
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSLock new];
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
    });

    [lock lock];
    @try {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSString *p = LPPath(@"log.txt");
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
        if (stat([p fileSystemRepresentation], &st) == 0 && st.st_size > 512 * 1024) {
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

// blatantsPatch: khi app group thật không tồn tại (sideload), dựng thư mục
// thay thế dưới ../Shared/AppGroup/<groupID> trong container của app.
// Đường dẫn phải ỔN ĐỊNH giữa các lần chạy — nếu đổi, dữ liệu cũ mất.
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

double LPVideoSeconds(void) {
    double v = [[LPConfig shared] dbl:@"maxVideoSeconds" fallback:600.0];
    return MAX(10.0, MIN(v, 3600.0));
}

double LPVideoBytes(void) {
    double v = [[LPConfig shared] dbl:@"maxVideoBytes" fallback:500.0 * 1024 * 1024];
    return MAX(5.0 * 1024 * 1024, MIN(v, 4096.0 * 1024 * 1024));
}

#pragma mark - bảng IMP gốc

static NSMutableDictionary<NSString *, NSValue *> *gIMPTable;
static NSLock *gIMPLock;

static NSString *LPIMPKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@|%@",
            NSStringFromClass(cls), NSStringFromSelector(sel)];
}

static void LPIMPTableInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gIMPTable = [NSMutableDictionary dictionary];
        gIMPLock = [NSLock new];
    });
}

void LPSetOrigIMP(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    LPIMPTableInit();
    [gIMPLock lock];
    gIMPTable[LPIMPKey(cls, sel)] = [NSValue valueWithPointer:imp];
    [gIMPLock unlock];
}

IMP LPOrigIMPFor(id self, SEL sel) {
    if (!self || !sel) return NULL;
    LPIMPTableInit();
    // Đi ngược chuỗi kế thừa: hook có thể nằm trên class cha.
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        [gIMPLock lock];
        NSValue *v = gIMPTable[LPIMPKey(c, sel)];
        [gIMPLock unlock];
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}

// Tra theo class chính xác (không đi lên cha) — dùng khi hook lặp.
IMP LPOrigIMPForClass(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    LPIMPTableInit();
    [gIMPLock lock];
    NSValue *v = gIMPTable[LPIMPKey(cls, sel)];
    [gIMPLock unlock];
    return v ? (IMP)v.pointerValue : NULL;
}

#pragma mark - hook an toàn

BOOL LPHookMethod(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP orig = method_getImplementation(m);
    // Đã hook rồi (hook lặp) → KHÔNG ghi IMP của chính mình làm "bản gốc",
    // nếu không sẽ đệ quy vô hạn. Lấy lại bản gốc đã lưu trong bảng.
    if (orig == newImp) {
        if (origOut) {
            IMP stored = LPOrigIMPForClass(cls, sel);
            *origOut = stored ?: orig;
        }
        return YES;
    }
    LPSetOrigIMP(cls, sel, orig);
    if (origOut) *origOut = orig;
    method_setImplementation(m, newImp);
    return YES;
}

BOOL LPHookMethodTyped(Class cls, SEL sel, const char *expectReturn,
                       IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || !enc[0]) return NO;
    if (expectReturn && expectReturn[0] && enc[0] != expectReturn[0]) {
        LPLog(@"[hook] BỎ %@.%@ — trả '%c', cần '%c'",
              NSStringFromClass(cls), NSStringFromSelector(sel), enc[0], expectReturn[0]);
        return NO;
    }
    return LPHookMethod(cls, sel, newImp, origOut);
}

// NSURLSession là class cluster: hook trên NSURLSession (class trừu tượng) chỉ
// ăn với session tạo bằng +sessionWithConfiguration:. Session của Firebase tạo
// qua __NSCFURLSession → phải hook thêm class cụ thể.
BOOL LPHookClassAndConcrete(Class cls, const char *concreteName,
                            SEL sel, IMP newImp, IMP *origOut) {
    BOOL any = NO;
    if (cls) {
        IMP o = NULL;
        if (LPHookMethod(cls, sel, newImp, &o)) {
            any = YES;
            if (origOut && !*origOut) *origOut = o;
        }
    }
    if (concreteName) {
        Class c = NSClassFromString([NSString stringWithUTF8String:concreteName]);
        if (c && c != cls) {
            IMP o = NULL;
            if (LPHookMethod(c, sel, newImp, &o)) {
                any = YES;
                if (origOut && !*origOut) *origOut = o;
            }
        }
    }
    return any;
}

void LPWhenClassReady(NSString *className, void (^block)(Class cls)) {
    if (!className.length || !block) return;
    Class c = NSClassFromString(className);
    if (c) { block(c); return; }

    __block int tries = 0;
    __block void (^retry)(void) = nil;
    retry = ^{
        Class cls = NSClassFromString(className);
        if (cls) { block(cls); return; }
        if (++tries > 60) {          // 60 × 0.5s = 30s
            LPLog(@"[hook] không thấy class %@", className);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), retry);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), retry);
}

#pragma mark - tầng mạng dùng chung

@implementation LPNetResult
@end

static NSMutableArray<LPNetProcessor> *gNetProcessors;
static NSLock *gNetLock;

static void LPNetInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gNetProcessors = [NSMutableArray array];
        gNetLock = [NSLock new];
    });
}

void LPAddNetProcessor(LPNetProcessor processor) {
    if (!processor) return;
    LPNetInit();
    [gNetLock lock];
    [gNetProcessors addObject:[processor copy]];
    [gNetLock unlock];
}

// Cho từng processor sửa kết quả. Processor PHẢI tự kiểm tra URL và trả về
// ngay nếu không liên quan — hàm này chạy cho MỌI response.
static void LPRunNetProcessors(NSURLRequest *req, LPNetResult *res) {
    LPNetInit();
    [gNetLock lock];
    NSArray *snapshot = [gNetProcessors copy];
    [gNetLock unlock];
    for (LPNetProcessor p in snapshot) {
        @try { p(req, res); }
        @catch (NSException *e) { LPLog(@"[net] processor lỗi: %@", e.reason); }
    }
}

#pragma mark - hook NSURLSession

static id LPDataTask(id self, SEL _cmd, NSURLRequest *req, id completion) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    void (^orig)(NSData *, NSURLResponse *, NSError *) =
        (void (^)(NSData *, NSURLResponse *, NSError *))completion;
    if (!orig) {
        return ((id (*)(id, SEL, NSURLRequest *, id))o)(self, _cmd, req, completion);
    }
    id wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        @autoreleasepool {
            @try {
                LPNetResult *r = [LPNetResult new];
                r.data = data;
                r.response = resp;
                LPRunNetProcessors(req, r);
                data = r.data;
                resp = r.response;
            } @catch (__unused NSException *e) {}
        }
        orig(data, resp, err);
    };
    return ((id (*)(id, SEL, NSURLRequest *, id))o)(self, _cmd, req, wrapped);
}

static id LPDataURLTask(id self, SEL _cmd, NSURL *url, id completion) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    void (^orig)(NSData *, NSURLResponse *, NSError *) =
        (void (^)(NSData *, NSURLResponse *, NSError *))completion;
    if (!orig) {
        return ((id (*)(id, SEL, NSURL *, id))o)(self, _cmd, url, completion);
    }
    NSURLRequest *req = url ? [NSURLRequest requestWithURL:url] : nil;
    id wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        @autoreleasepool {
            @try {
                LPNetResult *r = [LPNetResult new];
                r.data = data;
                r.response = resp;
                LPRunNetProcessors(req, r);
                data = r.data;
                resp = r.response;
            } @catch (__unused NSException *e) {}
        }
        orig(data, resp, err);
    };
    return ((id (*)(id, SEL, NSURL *, id))o)(self, _cmd, url, wrapped);
}

void LPInstallNetHooks(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    SEL a = @selector(dataTaskWithRequest:completionHandler:);
    SEL b = @selector(dataTaskWithURL:completionHandler:);

    // NSURLSession là class cluster. Hook lớp trừu tượng KHÔNG đủ: lớp cụ thể
    // (__NSCFURLSession) override lại. Phải hook TẤT CẢ subclass đang có, và
    // quét lại sau vài giây vì Firebase/RevenueCat tạo session muộn.
    NSMutableSet<NSString *> *names = [NSMutableSet setWithObject:@"NSURLSession"];
    [names addObject:@"__NSCFURLSession"];

    Class base = NSClassFromString(@"NSURLSession");
    if (base) {
        int count = objc_getClassList(NULL, 0);
        if (count > 0) {
            Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
            if (classes) {
                count = objc_getClassList(classes, count);
                for (int i = 0; i < count; i++) {
                    Class c = classes[i];
                    if (c == base) continue;
                    if (!class_getSuperclass(c)) continue;
                    BOOL isSub = NO;
                    for (Class p = class_getSuperclass(c); p; p = class_getSuperclass(p)) {
                        if (p == base) { isSub = YES; break; }
                    }
                    if (isSub) {
                        const char *n = class_getName(c);
                        if (n) [names addObject:[NSString stringWithUTF8String:n]];
                    }
                }
                free(classes);
            }
        }
    }

    NSInteger hooked = 0;
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        // Chỉ hook khi class THẬT SỰ có method (không tính thừa kế) — nếu
        // không sẽ sửa Method của lớp cha nhiều lần (vô hại nhưng thừa).
        if (class_getInstanceMethod(c, a)) {
            if (LPHookMethod(c, a, (IMP)LPDataTask, NULL)) hooked++;
        }
        if (class_getInstanceMethod(c, b)) {
            if (LPHookMethod(c, b, (IMP)LPDataURLTask, NULL)) hooked++;
        }
    }
    LPLog(@"[net] hook %ld method trên %lu class", (long)hooked, (unsigned long)names.count);

    // Quét lại: session của Firebase/RevenueCat có thể nạp sau.
    for (int i = 1; i <= 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            for (NSString *n in names) {
                Class c = NSClassFromString(n);
                if (!c) continue;
                if (!class_getInstanceMethod(c, a)) continue;
                if (method_getImplementation(class_getInstanceMethod(c, a)) == (IMP)LPDataTask) continue;
                LPHookMethod(c, a, (IMP)LPDataTask, NULL);
                LPHookMethod(c, b, (IMP)LPDataURLTask, NULL);
                LPLog(@"[net] hook muộn %@", n);
            }
        });
    }
}
