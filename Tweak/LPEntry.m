#import "LPCommon.h"
#import <objc/runtime.h>

//
// LPEntry — khởi động tweak. KHÔNG có nút nổi, KHÔNG có menu.
//
// Mọi thứ chạy ngầm hoặc nằm đúng chỗ trong giao diện gốc của Locket:
//   • Giới hạn video / mic / tỉ lệ  → tự động, cấu hình trong config.plist
//   • Gold                          → tự động
//   • Chẩn đoán kết bạn             → ghi log ra file, không hiện UI
//   • Ghi chú genz                  → thanh phụ trên bàn phím khi gõ caption
//   • Profile+                      → nút ✨ chỉ xuất hiện trên màn profile
//

static BOOL gBooted = NO;
static BOOL gProfileHooked = NO;
static Class gHookedProfileClass;
static void (*gOrigViewDidAppear)(id, SEL, BOOL);

#pragma mark - hook màn profile (để gắn nút Profile+)

static void LPProfileViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigViewDidAppear) gOrigViewDidAppear(self, _cmd, animated);
    // Chỉ gắn cho ĐÚNG class đã hook — không đụng class con/khác.
    if (!gHookedProfileClass || ![self isKindOfClass:gHookedProfileClass]) return;
    @try { LPInstallProfileButton((UIViewController *)self); }
    @catch (NSException *e) { LPLog(@"[profile] lỗi: %@", e); }
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

#pragma mark - boot

// Ghi bước đang chạy ra file NGAY LẬP TỨC (không buffer), để nếu app chết
// giữa chừng thì lần mở sau vẫn đọc được bước cuối cùng.
static void LPStep(const char *name) {
    NSString *p = [LPConfig path:@"boot.trace"];
    NSString *line = [NSString stringWithFormat:@"%s\n", name];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) {
        [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    @catch (__unused NSException *e) {}
}

static void LPBoot(void) {
    if (gBooted) return;
    gBooted = YES;

    // CHẾ ĐỘ AN TOÀN: nếu app từng crash, lần mở sau không hook gì cả.
    // Tắt bằng cách sửa "safeMode" = false trong Documents/LocketPlus/config.plist.
    if ([[LPConfig shared] flag:@"safeMode" fallback:NO]) {
        LPLog(@"[boot] SAFE MODE — không cài hook nào");
        return;
    }

    LPStep("media");
    @try { LPInstallMediaHooks(); }   @catch (NSException *e) { LPLog(@"[boot] media: %@", e); }
    LPStep("export");
    @try { LPInstallExportHooks(); }  @catch (NSException *e) { LPLog(@"[boot] export: %@", e); }
    LPStep("gold");
    @try { LPInstallGoldUnlock(); }   @catch (NSException *e) { LPLog(@"[boot] gold: %@", e); }
    LPStep("friend");
    @try { LPInstallFriendTools(); }  @catch (NSException *e) { LPLog(@"[boot] friend: %@", e); }
    // Tự chạy chẩn đoán 1 lần sau khi app ổn định, ghi ra friend.log (không UI).
    if ([[LPConfig shared] flag:@"friendProbeEnabled" fallback:YES]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { LPRunFriendProbe(nil); } @catch (__unused NSException *e) {}
        });
    }
    LPStep("patch");
    @try { LPApplyConfiguredPatches(); } @catch (NSException *e) { LPLog(@"[boot] patch: %@", e); }
    LPStep("notes");
    @try { LPInstallNotesAccessory(); } @catch (NSException *e) { LPLog(@"[boot] notes: %@", e); }
    LPStep("profile");
    @try { LPInstallProfileHook(); }  @catch (NSException *e) { LPLog(@"[boot] profile: %@", e); }

    LPStep("done");
    // 8 giây sau mà app còn sống → boot thành công, lần sau không bật safeMode.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LPMarkBootOK(); });
    LPLog(@"[boot] Locket+ v1.13 sẵn sàng (không menu)");
}

__attribute__((constructor))
static void LPInit(void) {
    // TUYỆT ĐỐI không đụng UIKit ở đây: dylib nạp trước khi UIApplication tồn tại.
    @autoreleasepool {
        // Bắt crash TRƯỚC TIÊN — nếu không, crash trong constructor sẽ không
        // được ghi lại và ta chỉ thấy log cụt 1 dòng.
        @try { LPInstallCrashHandler(); } @catch (__unused NSException *e) {}

        // Phải chạy TRƯỚC main(): app đụng app-group ngay màn hình đầu.
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
