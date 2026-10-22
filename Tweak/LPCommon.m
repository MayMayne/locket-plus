#import "LPCommon.h"

static LPConfig *gConfig;

@implementation LPConfig

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gConfig = [LPConfig new]; [gConfig reload]; });
    return gConfig;
}

+ (NSString *)dir {
    NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    d = [d stringByAppendingPathComponent:@"LocketPlus"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

+ (NSString *)path:(NSString *)name { return [[self dir] stringByAppendingPathComponent:name]; }

- (void)reload {
    NSString *p = [LPConfig path:@"config.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        NSDictionary *def = @{
            @"maxVideoSeconds": @600,
            @"maxVideoBytes": @(500.0 * 1024 * 1024),
            @"videoBitrate": @1600000,
            @"aggressiveScan": @YES,
            @"friendProbeEnabled": @YES,
            @"probeEndpoints": @[
                @"https://api.locketcamera.com/sendFriendRequest",
                @"https://us-central1-locket-4252a.cloudfunctions.net/sendFriendRequest"
            ],
            @"knownLimits": @[@15, @30, @60, @90, @120, @300, @(10.0*1024*1024), @(25.0*1024*1024),
                              @(100.0*1024*1024), @(104857600), @(500.0*1024*1024), @(524288000)]
        };
        [def writeToFile:p atomically:YES];
    }
    self.plist = [NSDictionary dictionaryWithContentsOfFile:p] ?: @{};
    LPLog(@"[cfg] loaded %lu keys", (unsigned long)self.plist.count);
}

- (id)obj:(NSString *)key fallback:(id)fb { id v = self.plist[key]; return v ?: fb; }
- (double)dbl:(NSString *)key fallback:(double)fb { id v = self.plist[key]; return v ? [v doubleValue] : fb; }
- (BOOL)flag:(NSString *)key fallback:(BOOL)fb { id v = self.plist[key]; return v ? [v boolValue] : fb; }
- (NSString *)str:(NSString *)key fallback:(NSString *)fb { id v = self.plist[key]; return [v isKindOfClass:[NSString class]] ? v : fb; }

+ (void)log:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSString *p = [LPConfig path:@"log.txt"];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) { [d writeToFile:p atomically:YES]; return; }
    @try { [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile]; } @catch (__unused NSException *e) {}
    struct stat st;
    if (stat([p fileSystemRepresentation], &st) == 0 && st.st_size > 512 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
    }
}

+ (NSString *)logText {
    return [NSString stringWithContentsOfFile:[LPConfig path:@"log.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"(log trống)";
}

@end

double LPVideoSeconds(void) { return MAX(10.0, [[LPConfig shared] dbl:@"maxVideoSeconds" fallback:600.0]); }
double LPVideoBytes(void)   { return MAX(5.0 * 1024 * 1024, [[LPConfig shared] dbl:@"maxVideoBytes" fallback:500.0 * 1024 * 1024]); }

#pragma mark - bảng IMP gốc

static NSMutableDictionary<NSString *, NSValue *> *gIMPTable;

static NSString *LPIMPKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
}

void LPSetOrigIMP(Class cls, SEL sel, IMP imp) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gIMPTable = [NSMutableDictionary dictionary]; });
    if (cls && sel && imp) gIMPTable[LPIMPKey(cls, sel)] = [NSValue valueWithPointer:imp];
}

IMP LPOrigIMPFor(id self, SEL sel) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        NSValue *v = gIMPTable[LPIMPKey(c, sel)];
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}

#pragma mark - hook an toàn

BOOL LPHookMethod(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP orig = method_getImplementation(m);
    if (orig == newImp) return YES;
    LPSetOrigIMP(cls, sel, orig);
    if (origOut) *origOut = orig;
    method_setImplementation(m, newImp);
    return YES;
}

Class LPFindClassWithMethod(NSArray<NSString *> *names, SEL sel) {
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (c && class_getInstanceMethod(c, sel)) return c;
    }
    return nil;
}

void LPWhenClassReady(NSString *className, void (^block)(Class cls)) {
    if (!className.length || !block) return;
    Class c = NSClassFromString(className);
    if (c) { block(c); return; }
    // Thử lại tối đa 40 lần trong 20s — Swift class của Locket có thể nạp
    // muộn hơn dylib, nhưng không được chờ vô hạn.
    __block int tries = 0;
    __block void (^retry)(void);
    retry = ^{
        Class cls = NSClassFromString(className);
        if (cls) { block(cls); return; }
        if (++tries > 40) { LPLog(@"[hook] không thấy class %@", className); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), retry);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), retry);
}

void LPShowAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = nil;
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *win in ((UIWindowScene *)sc).windows) if (win.isKeyWindow) w = win;
            }
        }
        UIViewController *vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

static UIViewController *LPResolveHost(UIViewController *host) {
    if (host) return host;
    UIWindow *w = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)sc).windows) if (win.isKeyWindow) w = win;
    }
    return w.rootViewController;
}

void LPShowText(UIViewController *host, NSString *title, NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = LPResolveHost(host);
        while (vc.presentedViewController) vc = vc.presentedViewController;
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
        tv.text = text ?: @"";
        tv.editable = NO;
        tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        UIViewController *c = [UIViewController new];
        c.title = title;
        tv.frame = c.view.bounds;
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [c.view addSubview:tv];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:c];
        [vc presentViewController:nav animated:YES completion:nil];
    });
}

@implementation LPProfileModel

+ (instancetype)load {
    LPProfileModel *m = [LPProfileModel new];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[LPConfig path:@"profile.plist"]];
    if (!d) d = @{};
    m.displayName = d[@"displayName"] ?: @"";
    m.quote = d[@"quote"] ?: @"";
    m.songTitle = d[@"songTitle"] ?: @"";
    m.songArtist = d[@"songArtist"] ?: @"";
    m.lyrics = d[@"lyrics"] ?: @"";
    m.coverName = d[@"coverName"] ?: @"";
    m.avatarName = d[@"avatarName"] ?: @"";
    m.featured = [NSMutableArray arrayWithArray:d[@"featured"] ?: @[]];
    m.bestFriends = [NSMutableArray array];
    for (NSDictionary *f in d[@"bestFriends"] ?: @[]) [m.bestFriends addObject:[f mutableCopy]];
    return m;
}

- (void)save {
    NSDictionary *d = @{
        @"displayName": self.displayName ?: @"",
        @"quote": self.quote ?: @"",
        @"songTitle": self.songTitle ?: @"",
        @"songArtist": self.songArtist ?: @"",
        @"lyrics": self.lyrics ?: @"",
        @"coverName": self.coverName ?: @"",
        @"avatarName": self.avatarName ?: @"",
        @"featured": self.featured ?: @[],
        @"bestFriends": self.bestFriends ?: @[]
    };
    [d writeToFile:[LPConfig path:@"profile.plist"] atomically:YES];
}

@end
