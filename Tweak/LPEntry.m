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
        LPInstallUpload();
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
            LPLog(@"[boot] LocketPlus v6.4 nạp");
        } @catch (__unused NSException *e) {}

        // 3: keychain/app-group — phải xong trước Firebase Auth.
        if (!LPSafeMode()) {
            @try { LPInstallSideloadFixes(); }
            @catch (NSException *e) { LPLog(@"[boot] sideload lỗi: %@", e.reason); }

            // 3b: MEDIA phải cài NGAY, không chờ app lên.
            //
            // Locket pre-warm AVCaptureSession lúc khởi động và đặt
            // maxRecordedDuration = 15s ở đó. Nếu ta cài hook sau (600ms) thì
            // lời gọi đó đã xảy ra rồi → trần vẫn 15 giây. Đây đúng là triệu
            // chứng "quay được có 15 giây".
            //
            // AVFoundation đã nạp sẵn khi dylib này được dyld nạp (Locket link
            // AVFoundation), nên swizzle ở đây an toàn.
            @try { LPInstallMedia(); }
            @catch (NSException *e) { LPLog(@"[boot] media lỗi: %@", e.reason); }

            // 3c: probe — chỉ ghi log, không sửa gì. Bật bằng probeEnabled.
            @try { LPInstallProbe(); }
            @catch (__unused NSException *e) {}

            // 3d: dò class thật của Locket — chỉ đọc. Bật bằng discoverEnabled.
            @try { LPInstallDiscover(); }
            @catch (__unused NSException *e) {}
        } else {
            LPLog(@"[boot] safeMode — bỏ qua sideload fix");
        }

        // Watchdog: ghi hang.txt nếu 8s sau vẫn chưa boot xong.
        @try { LPWatchdogStart(); } @catch (__unused NSException *e) {}

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
