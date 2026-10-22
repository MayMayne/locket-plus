// ============================================================================
//  LPEntry.m — điểm vào duy nhất
//
//  THỨ TỰ BẮT BUỘC (rút ra từ 6 bản crash):
//    1. Crash handler  — phải có TRƯỚC mọi thứ, nếu không crash trong
//                        constructor không được ghi lại (lỗi v1.12).
//    2. Boot counter   — chết 2 lần liên tiếp → safeMode.
//    3. Sideload fix   — TRONG constructor, TRƯỚC khi Firebase Auth kịp đọc
//                        keychain. Đây là điều kiện sống của app.
//    4. Mọi thứ khác   — sau khi app lên (main queue), bọc @try.
//
//  KHÔNG hook gì trong constructor ngoài 2 việc trên. Dylib nạp trước khi
//  UIApplication tồn tại; đụng UIKit/AVFoundation ở đó là chết.
// ============================================================================

#import "LPCommon.h"

static BOOL gLateInstalled = NO;

static void LPInstallLate(void) {
    if (gLateInstalled) return;
    gLateInstalled = YES;

    @try {
        LPInstallNetHooks();
        LPInstallGold();
        LPInstallMedia();
        LPMarkBootOK();
    } @catch (NSException *e) {
        LPLog(@"[boot] lỗi cài đặt: %@", e.reason);
        LPWriteCrashText([NSString stringWithFormat:@"\n=== INSTALL FAILED ===\n%@\n",
                          e.reason ?: @"?"]);
    }
}

__attribute__((constructor))
static void LPInit(void) {
    @autoreleasepool {
        // 1 + 2: an toàn, chỉ dùng POSIX + Foundation cơ bản.
        @try {
            LPInstallCrashHandler();
            LPBootBegin();
            LPLog(@"[boot] LocketPlus v5.0 nạp");
        } @catch (__unused NSException *e) {}

        // 3: keychain/app-group — phải xong trước Firebase Auth.
        if (!LPSafeMode()) {
            @try { LPInstallSideloadFixes(); }
            @catch (NSException *e) { LPLog(@"[boot] sideload lỗi: %@", e.reason); }
        } else {
            LPLog(@"[boot] safeMode — bỏ qua sideload fix");
        }

        // 4: phần còn lại sau khi app lên.
        dispatch_async(dispatch_get_main_queue(), ^{
            // Chờ 1 nhịp cho UIApplication + AVFoundation sẵn sàng.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                if (LPSafeMode()) {
                    LPLog(@"[boot] safeMode — không hook gì");
                    LPMarkBootOK();
                    return;
                }
                LPInstallLate();
            });
        });
    }
}
