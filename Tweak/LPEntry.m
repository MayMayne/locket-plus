#import "LPCommon.h"
#import <objc/runtime.h>

//
// LPEntry — nút nổi L+ và hook màn hình profile.
//
// SỬA: hook viewDidAppear trên class Swift phải CHỜ class xuất hiện
// (LPWhenClassReady). Trước đây gọi objc_getClass ngay trong constructor
// nên hầu như luôn nil → nút ✨ không bao giờ được gắn.
//

static UIButton *gFab;
static BOOL gBooted = NO;
static BOOL gProfileHooked = NO;

static UIWindow *LPKeyWindow(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

@interface LPFabHandler : NSObject
+ (instancetype)shared;
- (void)show;
- (void)showDiag;
@end

static void LPInstallFab(void) {
    UIWindow *w = LPKeyWindow();
    if (!w || gFab) return;
    CGFloat size = 44;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(w.bounds.size.width - size - 14,
                         w.bounds.size.height - size - 110, size, size);
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    b.backgroundColor = [UIColor colorWithRed:0.98 green:0.55 blue:0.15 alpha:0.92];
    b.layer.cornerRadius = size / 2;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.2;
    b.layer.shadowRadius = 6;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    [b setTitle:@"L+" forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:[LPFabHandler shared] action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[LPFabHandler shared] action:@selector(showDiag)];
    [b addGestureRecognizer:lp];
    [w addSubview:b];
    gFab = b;
    LPLog(@"[ui] FAB đã gắn");
}

@implementation LPFabHandler
+ (instancetype)shared {
    static LPFabHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [LPFabHandler new]; });
    return h;
}

- (UIViewController *)topVC {
    UIViewController *vc = LPKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

- (void)show { LPShowHub([self topVC]); }
- (void)showDiag { LPRunFriendProbe([self topVC]); }
@end

#pragma mark - hook profile

static void (*gOrigViewDidAppear)(id, SEL, BOOL);
static Class gHookedProfileClass;

static void LPProfileViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    // Chỉ gắn nút cho ĐÚNG class đã hook — không đụng class con/khác.
    if (!gHookedProfileClass || ![self isKindOfClass:gHookedProfileClass]) return;
    @try { LPInstallProfileButton((UIViewController *)self); } @catch (NSException *e) { LPLog(@"[profile] lỗi: %@", e); }
}

static void LPInstallProfileHook(void) {
    if (gProfileHooked) return;
    NSArray *names = @[@"_TtC14JournalFeature27ProfileMenuV2ViewController",
                       @"_TtC15SettingsFeature31SettingsMenuSheetViewController"];
    for (NSString *n in names) {
        LPWhenClassReady(n, ^(Class cls) {
            if (gProfileHooked) return;
            SEL sel = @selector(viewDidAppear:);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) return;
            gOrigViewDidAppear = (void *)method_getImplementation(m);
            gHookedProfileClass = cls;
            method_setImplementation(m, (IMP)LPProfileViewDidAppear);
            gProfileHooked = YES;
            LPLog(@"[profile] hook %@", n);
        });
    }
}

// Chỉ chạy sau khi UIKit đã sống. Mọi lỗi trong từng khối đều bị nuốt để không làm app chết.
static void LPBoot(void) {
    if (gBooted) return;
    gBooted = YES;
    LPInstallCrashHandler();

    // CHẾ ĐỘ AN TOÀN: nếu app từng crash, lần mở sau chỉ gắn FAB + log,
    // không hook gì cả. Vào L+ → Tắt chế độ an toàn để bật lại từng phần.
    if ([[LPConfig shared] flag:@"safeMode" fallback:NO]) {
        LPLog(@"[boot] SAFE MODE — không cài hook nào");
        @try { LPInstallFab(); } @catch (__unused NSException *e) {}
        return;
    }

    @try { LPInstallMediaHooks(); } @catch (NSException *e) { LPLog(@"[boot] media lỗi: %@", e); }
    @try { LPInstallGoldUnlock(); } @catch (NSException *e) { LPLog(@"[boot] gold lỗi: %@", e); }
    @try { LPInstallFriendTools(); } @catch (NSException *e) { LPLog(@"[boot] friend lỗi: %@", e); }
    @try { LPApplyConfiguredPatches(); } @catch (NSException *e) { LPLog(@"[boot] patch lỗi: %@", e); }
    @try { LPInstallProfileHook(); } @catch (NSException *e) { LPLog(@"[boot] profile lỗi: %@", e); }
    @try { LPInstallFab(); } @catch (NSException *e) { LPLog(@"[boot] fab lỗi: %@", e); }
    LPLog(@"[boot] Locket+ v1.6 sẵn sàng");
}

__attribute__((constructor))
static void LPInit(void) {
    // TUYỆT ĐỐI không đụng UIKit ở đây: dylib được nạp trước khi UIApplication tồn tại.
    @autoreleasepool {
        // Phải chạy TRƯỚC main(): app đụng app-group + keychain ngay màn hình đầu.
        @try { LPInstallSideloadFixes(); } @catch (__unused NSException *e) {}
        // Thoát sạch (vuốt app / về home) → xoá cờ để lần sau không bật safeMode.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillTerminateNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(NSNotification *n) {
            NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            [[NSFileManager defaultManager] removeItemAtPath:
                [[dir stringByAppendingPathComponent:@"LocketPlus"] stringByAppendingPathComponent:@"running.flag"]
                                                       error:nil];
        }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ LPBoot(); });
        }];
    }
}
