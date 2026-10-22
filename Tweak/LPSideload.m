// ============================================================================
//  LPSideload.m — sống sót khi cài sideload (gộp từ LocketPatch.x)
//
//  Vì sao app chết ngay khi mở bản ký lại:
//    Entitlements gốc xin app-group + keychain-access-group của team
//    SWD4AZY4KG. AltStore/Sideloadly/ESign ký lại bằng team khác → không có
//    group đó. Khi chạy:
//      • containerURLForSecurityApplicationGroupIdentifier: trả nil → app
//        force-unwrap nil → crash.
//      • SecItemAdd với kSecAttrAccessGroup không tồn tại → errSecMissingEntitlement
//        → app coi là lỗi chí mạng.
//
//  Cách chữa: tạo container trên đĩa + bỏ kSecAttrAccessGroup khỏi mọi query
//  keychain (nil = dùng group thật của bản đã ký lại).
//
//  LƯU Ý: phần này chạy trong constructor, TRƯỚC main(), vì app đụng Keychain
//  ngay ở màn hình đầu. Không được dùng UIKit ở đây.
// ============================================================================

#import "LPCommon.h"
#import <Security/Security.h>
#import <dlfcn.h>
#import <string.h>

static NSString *const kLPAppGroupID = @"group.com.locket.Locket-Shared";

#pragma mark - app group container

static NSString *LPAppGroupPath(void) {
    NSURL *u = [[NSFileManager defaultManager]
                containerURLForSecurityApplicationGroupIdentifier:kLPAppGroupID];
    if (u) return u.path;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *grp = [base stringByAppendingPathComponent:@"../Shared/AppGroup"];
    return [grp stringByAppendingPathComponent:kLPAppGroupID];
}

static void LPEnsureGroupContainer(void) {
    NSString *path = LPAppGroupPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) return;
    NSError *err = nil;
    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&err];
    LPLog(@"[sideload] app-group %@: %@", err ? @"lỗi" : @"đã tạo", err ?: path);
}

#pragma mark - keychain

// Trả về query đã bỏ kSecAttrAccessGroup. Bản gốc dùng
// CFBridgingRelease(m) — sai: trả về object đã bị release → over-release.
static CFDictionaryRef LPSanitize(CFDictionaryRef query) {
    if (!query) return query;
    if (!CFDictionaryContainsKey(query, kSecAttrAccessGroup)) return query;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (!m) return query;
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    return m;   // caller phải CFRelease
}

typedef OSStatus (*LPSecItemFn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*LPSecItemUpdFn)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*LPSecItemDelFn)(CFDictionaryRef);

static LPSecItemFn gOrigAdd, gOrigCopy;
static LPSecItemUpdFn gOrigUpd;
static LPSecItemDelFn gOrigDel;

static OSStatus LPWrap2(LPSecItemFn orig, CFDictionaryRef q, CFTypeRef *res) {
    if (!orig) return errSecParam;
    CFDictionaryRef s = LPSanitize(q);
    OSStatus st = orig(s, res);
    if (s != q) CFRelease(s);
    return st;
}

static OSStatus LPAdd(CFDictionaryRef q, CFTypeRef *res) { return LPWrap2(gOrigAdd, q, res); }
static OSStatus LPCopy(CFDictionaryRef q, CFTypeRef *res) { return LPWrap2(gOrigCopy, q, res); }

static OSStatus LPUpdate(CFDictionaryRef q, CFDictionaryRef attrs) {
    if (!gOrigUpd) return errSecParam;
    CFDictionaryRef s = LPSanitize(q);
    OSStatus st = gOrigUpd(s, attrs);
    if (s != q) CFRelease(s);
    return st;
}

static OSStatus LPDelete(CFDictionaryRef q) {
    if (!gOrigDel) return errSecParam;
    CFDictionaryRef s = LPSanitize(q);
    OSStatus st = gOrigDel(s);
    if (s != q) CFRelease(s);
    return st;
}

// MSHookFunction của CydiaSubstrate không có trên máy không jailbreak.
// Dùng hook nội bộ của chính dylib (LPHookFunction) — vá 16 byte đầu hàm.
typedef void (*LPFuncHook)(void *target, void *replacement, void **original);

void LPInstallSideloadFixes(void) {
    @autoreleasepool {
        @try { LPEnsureGroupContainer(); } @catch (__unused NSException *e) {}

        // Lấy hook engine của substrate nếu app đã nạp nó; nếu không thì bỏ qua
        // (app vẫn chạy được nhờ app-group container; keychain chỉ lỗi khi
        // app thực sự ghi keychain với access group sai).
        void *sym = dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (!sym) {
            LPLog(@"[sideload] không có MSHookFunction → chỉ tạo app-group");
            return;
        }
        LPFuncHook hook = (LPFuncHook)sym;
        hook((void *)SecItemAdd, (void *)LPAdd, (void **)&gOrigAdd);
        hook((void *)SecItemCopyMatching, (void *)LPCopy, (void **)&gOrigCopy);
        hook((void *)SecItemUpdate, (void *)LPUpdate, (void **)&gOrigUpd);
        hook((void *)SecItemDelete, (void *)LPDelete, (void **)&gOrigDel);
        LPLog(@"[sideload] SecItem* đã rebind");
    }
}
