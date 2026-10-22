// ============================================================================
//  LPEntry.m — khởi động
//
//  Thứ tự BẮT BUỘC (rút ra từ các lần crash trước):
//    1. Crash handler — nếu không, crash trong constructor không được ghi lại
//    2. Sideload fixes — app đụng app-group + keychain ngay màn hình đầu tiên
//    3. Chờ app launch xong (0.6s) rồi mới cài hook của app
//
//  KHÔNG đụng UIKit trong constructor: dylib nạp trước khi UIApplication tồn tại.
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>

void LPBootStep(const char *name);

static BOOL gBooted = NO;

static void LPBoot(void) {
    if (gBooted) return;
    gBooted = YES;

    if ([[LPConfig shared] flag:@"safeMode" fallback:NO]) {
        LPLog(@"[boot] SAFE MODE — không cài hook nào. Sửa safeMode=false trong config.plist.");
        return;
    }

    LPBootStep("net");
    @try { LPInstallNetHooks(); }
    @catch (NSException *e) { LPLog(@"[boot] net: %@", e.reason); }

    LPBootStep("media");
    @try { LPInstallMediaHooks(); }
    @catch (NSException *e) { LPLog(@"[boot] media: %@", e.reason); }

    LPBootStep("rc");
    @try { LPInstallRemoteConfigHooks(); }
    @catch (NSException *e) { LPLog(@"[boot] rc: %@", e.reason); }

    LPBootStep("gold");
    @try { LPInvalidateRevenueCatCacheOnce(); LPInstallGoldNetProcessor(); LPInstallGoldHooks(); }
    @catch (NSException *e) { LPLog(@"[boot] gold: %@", e.reason); }

    LPBootStep("friend");
    @try { LPInstallFriendTools(); }
    @catch (NSException *e) { LPLog(@"[boot] friend: %@", e.reason); }

    // Probe chạy ngầm, ghi file, không hiện UI.
    if ([[LPConfig shared] flag:@"friendDiagnostics" fallback:YES]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { LPRunFriendProbe(); } @catch (__unused NSException *e) {}
        });
    }

    LPBootStep("done");

    // 8s sau mà app còn sống → boot thành công.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LPMarkBootOK(); });

    LPLog(@"[boot] Locket+ v2.0 sẵn sàng");
}

__attribute__((constructor))
static void LPInit(void) {
    @autoreleasepool {
        // 1) Bắt crash TRƯỚC TIÊN.
        @try { LPInstallCrashHandler(); } @catch (__unused NSException *e) {}

        // 2) Sideload fixes phải chạy TRƯỚC main().
        @try { LPInstallSideloadFixes(); } @catch (__unused NSException *e) {}

        // 3) Chờ app launch xong rồi mới hook app.
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ LPBoot(); });
        }];
    }
}
