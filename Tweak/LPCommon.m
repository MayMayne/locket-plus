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
            @"mediaEnabled"         : @YES,
            @"maxVideoSeconds"      : @600,
            @"maxVideoBytes"        : @(500.0 * 1024 * 1024),
            @"keepMicOnRecord"      : @YES,
            @"addMicInput"          : @YES,
            @"goldUnlock"           : @YES,
            @"friendLimitUnlock"    : @YES,
            @"expandExportRange"    : @NO,
            @"compressForUpload"    : @NO,
            @"uploadTargetBytes"    : @(6.0 * 1024 * 1024),
            @"exportMultiPass"      : @NO,
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

- (id)obj:(NSString *)key {
    return key ? self.plist[key] : nil;
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

#pragma mark - hook an toàn (bám sát _Hook của MHVideoPipeline + blatantsPatch)

// TÌM CLASS SỞ HỮU METHOD THẬT.
//
// Đây là khác biệt quyết định so với bản trước của tôi:
//
//   SAI (bản cũ): class_getInstanceMethod(cls, sel) → nếu cls KHÔNG tự cài
//   method, hàm này ĐI LÊN class cha và trả Method của CHA. Rồi
//   method_setImplementation sửa Method của CHA → ảnh hưởng MỌI subclass.
//   Ví dụ hook -[NSURLSession dataTaskWithRequest:] khi method thật nằm ở
//   __NSCFURLSession: mọi session trong app (kể cả của hệ thống) đều chạy qua
//   code của tôi, và một chỗ sai ABI là chết toàn app.
//
//   ĐÚNG (cả 2 dylib mẫu đều làm thế — _Hook @0x8364 của MHVideoPipeline,
//   _ObserveMethod @0x4570 của blatantsPatch): duyệt class_copyMethodList
//   từng class trong chuỗi kế thừa để biết CHÍNH XÁC class nào sở hữu method:
//     • owner == class đích  → method_setImplementation (sửa tại chỗ)
//     • owner != class đích  → class_addMethod lên class đích (tạo bản riêng,
//                              class cha và các sibling KHÔNG bị đụng)
static Method LPOwnedMethod(Class cls, SEL sel, Class *ownerOut) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        if (!list) continue;
        Method found = NULL;
        for (unsigned i = 0; i < n; i++) {
            if (method_getName(list[i]) == sel) { found = list[i]; break; }
        }
        free(list);
        if (found) {
            if (ownerOut) *ownerOut = c;
            return found;
        }
    }
    return NULL;
}

BOOL LPHookMethod(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;

    Class owner = Nil;
    Method m = LPOwnedMethod(cls, sel, &owner);
    if (!m) return NO;

    IMP orig = method_getImplementation(m);
    // Đã hook rồi (hook lặp) → không ghi IMP của chính mình làm "bản gốc".
    if (orig == newImp) {
        if (origOut) *origOut = LPOrigIMPForClass(cls, sel) ?: orig;
        return YES;
    }

    if (owner == cls) {
        LPSetOrigIMP(cls, sel, orig);
        if (origOut) *origOut = orig;
        method_setImplementation(m, newImp);
        return YES;
    }

    // Method thừa kế từ class cha → thêm bản riêng cho class đích.
    // Nhờ vậy class cha và các subclass khác KHÔNG bị ảnh hưởng.
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;
    LPSetOrigIMP(cls, sel, orig);
    if (origOut) *origOut = orig;
    if (class_addMethod(cls, sel, newImp, types)) return YES;

    // class_addMethod fail (hiếm) → đành sửa tại chỗ.
    method_setImplementation(m, newImp);
    return YES;
}

BOOL LPHookMethodTyped(Class cls, SEL sel, const char *expectReturn,
                       IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Class owner = Nil;
    Method m = LPOwnedMethod(cls, sel, &owner);
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

    // KHÔNG đệ quy: đặt sẵn N lần kiểm tra. Cách cũ (block tự gọi lại chính nó)
    // tạo retain cycle trong ARC vì __block object bị retain khi capture →
    // rò rỉ vĩnh viễn mỗi lần chờ một class không tồn tại.
    //
    // __block BOOL là kiểu nguyên thuỷ → block không retain gì → không cycle.
    __block BOOL done = NO;
    const int kTries = 60;                    // 60 × 0.5s = 30s
    for (int i = 1; i <= kTries; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (done) return;
            Class cls = NSClassFromString(className);
            if (!cls) {
                if (i == kTries) LPLog(@"[hook] không thấy class %@", className);
                return;
            }
            done = YES;
            block(cls);
        });
    }
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

// Chỉ bọc completion khi CÓ processor quan tâm URL này. Trước đây tôi bọc
// MỌI request (kể cả tải ảnh, video, WebSocket) → mỗi response đều đi qua code
// của tweak, và bất kỳ lỗi nào cũng làm app chết. Giờ lọc trước.
static BOOL LPAnyProcessorWants(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";

    // RevenueCat (Gold)
    if ([host isEqualToString:@"api.revenuecat.com"] ||
        [host hasSuffix:@".revenuecat.com"]) {
        if ([path containsString:@"/v1/subscribers/"] ||
            [path containsString:@"/v1/receipts"]) return YES;
    }
    // Locket friend endpoints
    if ([host isEqualToString:@"api.locketcamera.com"] ||
        [host hasSuffix:@"cloudfunctions.net"] ||
        [host hasSuffix:@".run.app"]) {
        if ([path containsString:@"friend"]) return YES;
    }
    return NO;
}

static id LPDataTask(id self, SEL _cmd, NSURLRequest *req, id completion) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;

    // Không quan tâm → gọi thẳng, KHÔNG bọc. Đây là đường đi của 99% request.
    if (!LPAnyProcessorWants(req.URL)) {
        return ((id (*)(id, SEL, NSURLRequest *, id))o)(self, _cmd, req, completion);
    }

    void (^orig)(NSData *, NSURLResponse *, NSError *) =
        (void (^)(NSData *, NSURLResponse *, NSError *))completion;
    if (!orig) {
        return ((id (*)(id, SEL, NSURLRequest *, id))o)(self, _cmd, req, completion);
    }
    id wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        LPTrace("net.completion");
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
        LPTrace("net.call-orig");
        orig(data, resp, err);
    };
    return ((id (*)(id, SEL, NSURLRequest *, id))o)(self, _cmd, req, wrapped);
}

static id LPDataURLTask(id self, SEL _cmd, NSURL *url, id completion) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;

    if (!LPAnyProcessorWants(url)) {
        return ((id (*)(id, SEL, NSURL *, id))o)(self, _cmd, url, completion);
    }

    void (^orig)(NSData *, NSURLResponse *, NSError *) =
        (void (^)(NSData *, NSURLResponse *, NSError *))completion;
    if (!orig) {
        return ((id (*)(id, SEL, NSURL *, id))o)(self, _cmd, url, completion);
    }
    NSURLRequest *req = [NSURLRequest requestWithURL:url];
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

    // BÁM SÁT AutoRcSideload: nó hook ĐÚNG MỘT class là NSURLSession, và chỉ
    // 2 selector dataTask*. Bản trước của tôi quét MỌI subclass (6 class, 10
    // method) — gồm cả class private của hệ thống. Đó là hook quá rộng:
    // mỗi response của app đều đi qua code của tôi, và bất kỳ lỗi nào trong
    // đó (hoặc ABI sai ở một subclass) đều làm app chết.
    //
    // NSURLSession là class trừu tượng nhưng method nằm ngay trên nó, và
    // __NSCFURLSession KHÔNG override 2 selector này — nên hook 1 class là đủ.
    Class s = NSClassFromString(@"NSURLSession");
    if (!s) { LPLog(@"[net] không có NSURLSession"); return; }

    SEL a = @selector(dataTaskWithRequest:completionHandler:);
    SEL b = @selector(dataTaskWithURL:completionHandler:);

    BOOL okA = LPHookMethod(s, a, (IMP)LPDataTask, NULL);
    BOOL okB = LPHookMethod(s, b, (IMP)LPDataURLTask, NULL);
    LPLog(@"[net] hook NSURLSession request=%d url=%d", okA, okB);

    if (!okA && !okB) LPLog(@"[net] không hook được — Gold/Friend sẽ không thấy response");
}
