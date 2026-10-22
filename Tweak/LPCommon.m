// ============================================================================
//  LPCommon.m — config, log, hook an toàn
// ============================================================================

#import "LPCommon.h"
#import <sys/stat.h>
#import <string.h>

static LPConfig *gConfig;

@implementation LPConfig

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gConfig = [LPConfig new];
        NSString *p = LPPath(@"config.plist");
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (![d isKindOfClass:[NSDictionary class]]) {
            d = @{ @"maxVideoSeconds": @600,
                   @"maxVideoBytes": @(500.0 * 1024 * 1024),
                   @"safeMode": @NO };
            [d writeToFile:p atomically:YES];
        }
        gConfig.plist = d;
    });
    return gConfig;
}

- (BOOL)flag:(NSString *)key fallback:(BOOL)fb {
    id v = self.plist[key];
    return v ? [v boolValue] : fb;
}

- (double)dbl:(NSString *)key fallback:(double)fb {
    id v = self.plist[key];
    return v ? [v doubleValue] : fb;
}

+ (NSString *)dir { return LPDir(); }
+ (NSString *)path:(NSString *)name { return LPPath(name); }

// Thread-safe: hook chạy trên capture/network/main thread cùng lúc.
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
        if (stat([p fileSystemRepresentation], &st) == 0 && st.st_size > 256 * 1024) {
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
        }
    } @catch (__unused NSException *e) {}
    [lock unlock];
}

@end

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

static NSMutableDictionary<NSString *, NSValue *> *gIMP;
static NSLock *gIMPLock;

static NSString *LPKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}

static void LPIMPInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gIMP = [NSMutableDictionary dictionary];
        gIMPLock = [NSLock new];
    });
}

IMP LPOrigIMPFor(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    LPIMPInit();
    [gIMPLock lock];
    NSValue *v = gIMP[LPKey(cls, sel)];
    [gIMPLock unlock];
    return v ? (IMP)v.pointerValue : NULL;
}

#pragma mark - hook (đúng kỹ thuật của 2 dylib mẫu)

// Tìm class SỞ HỮU method thật.
// class_getInstanceMethod() đi lên class cha → method_setImplementation sẽ
// sửa Method của CHA và ảnh hưởng mọi subclass. Đó là lỗi của bản trước.
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
    Method m = LPOwned(cls, sel, &owner);
    if (!m) return NO;

    IMP orig = method_getImplementation(m);
    if (orig == newImp) {                 // đã hook rồi
        if (origOut) *origOut = LPOrigIMPFor(cls, sel) ?: orig;
        return YES;
    }

    LPIMPInit();
    [gIMPLock lock];
    gIMP[LPKey(cls, sel)] = [NSValue valueWithPointer:orig];
    [gIMPLock unlock];
    if (origOut) *origOut = orig;

    if (owner == cls) {
        method_setImplementation(m, newImp);
        return YES;
    }

    // Method thừa kế → thêm bản riêng cho class đích, class cha không bị đụng.
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;
    if (class_addMethod(cls, sel, newImp, types)) return YES;
    method_setImplementation(m, newImp);
    return YES;
}

BOOL LPHookMethodTyped(Class cls, SEL sel, const char *expectReturn,
                       IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Class owner = Nil;
    Method m = LPOwned(cls, sel, &owner);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || !enc[0]) return NO;
    if (expectReturn && expectReturn[0] && enc[0] != expectReturn[0]) {
        LPLog(@"[hook] BỎ %s.%s — trả '%c', cần '%c'",
              class_getName(cls), sel_getName(sel), enc[0], expectReturn[0]);
        return NO;
    }
    return LPHookMethod(cls, sel, newImp, origOut);
}
