#import "LPCommon.h"
#import <objc/runtime.h>

@class LPFabHandler;

static UIButton *gFab;
static BOOL gBooted = NO;

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
    static LPFabHandler *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [LPFabHandler new]; });
    return s;
}
- (UIViewController *)topVC {
    UIViewController *vc = LPKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
- (void)show { LPShowHub([self topVC]); }
- (void)showDiag { LPRunFriendProbe([self topVC]); }
@end

void LPApplyConfiguredPatches(void);

// Chỉ chạy sau khi UIKit đã sống. Mọi lỗi trong từng khối đều bị nuốt để không làm app chết.
static void LPBoot(void) {
    if (gBooted) return;
    gBooted = YES;
    @try { LPInstallMediaHooks(); } @catch (NSException *e) { LPLog(@"[boot] media lỗi: %@", e); }
    @try { LPInstallFriendTools(); } @catch (NSException *e) { LPLog(@"[boot] friend lỗi: %@", e); }
    @try { LPApplyConfiguredPatches(); } @catch (NSException *e) { LPLog(@"[boot] patch lỗi: %@", e); }
    @try { LPInstallProfileUI(); } @catch (NSException *e) { LPLog(@"[boot] profile lỗi: %@", e); }
    @try { LPInstallFab(); } @catch (NSException *e) { LPLog(@"[boot] fab lỗi: %@", e); }
    LPLog(@"[boot] Locket+ v1.1 sẵn sàng");
}

__attribute__((constructor))
static void LPInit(void) {
    // TUYỆT ĐỐI không đụng UIKit ở đây: dylib được nạp trước khi UIApplication tồn tại.
    // Chỉ đăng ký, rồi chờ thông báo "app đã mở xong".
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ LPBoot(); });
        }];
    }
}
