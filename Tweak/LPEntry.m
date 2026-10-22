// ============================================================================
//  LPEntry.m — khởi động
//
//  Thứ tự bắt buộc:
//    1. Crash handler  (nếu không, crash trong constructor không được ghi)
//    2. Sideload fixes (app đụng app-group + keychain ngay màn hình đầu)
//    3. Chờ app launch xong 0.6s rồi mới hook
//
//  KHÔNG đụng UIKit trong constructor: dylib nạp trước khi UIApplication tồn tại.
// ============================================================================

#import "LPCommon.h"

void LPBootStep(const char *name);

static BOOL gBooted = NO;

static void LPBoot(void) {
    if (gBooted) return;
    gBooted = YES;

    if ([[LPConfig shared] flag:@"safeMode" fallback:NO]) {
        LPLog(@"[boot] SAFE MODE — không cài hook. Sửa safeMode=false trong config.plist.");
        LPMarkBootOK();
        return;
    }

    LPBootStep("media");
    @try { LPInstallMediaHooks(); }
    @catch (NSException *e) { LPLog(@"[boot] media: %@", e.reason); }

    LPBootStep("done");
    LPLog(@"[boot] Locket+ v3.0 sẵn sàng — %.0fs / %.0fMB",
          LPVideoSeconds(), LPVideoBytes() / 1048576.0);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LPMarkBootOK(); });
}

__attribute__((constructor))
static void LPInit(void) {
    @autoreleasepool {
        @try { LPInstallCrashHandler(); } @catch (__unused NSException *e) {}
        @try { LPInstallSideloadFixes(); } @catch (__unused NSException *e) {}

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                   usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ LPBoot(); });
        }];
    }
}
