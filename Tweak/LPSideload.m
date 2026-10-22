// ============================================================================
//  LPSideload.m — sống sót khi cài sideload
//
//  BÀI HỌC TỪ CRASH: bản trước dùng MSHookFunction để vá thẳng SecItemAdd /
//  SecItemCopyMatching (hàm C trong dyld shared cache). Trên iOS 15+ việc vá
//  hàm hệ thống như vậy làm app chết NGAY trong constructor — log chỉ kịp ghi
//  1 dòng rồi tắt.
//
//  Cách của blatantsPatch.dylib (bản KHÔNG crash): chỉ swizzle MỘT method ObjC
//  là -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:],
//  trả về thư mục có thật. Không đụng hàm C nào, không cần substrate.
//
//  Vì vậy ở đây bỏ hoàn toàn MSHookFunction và bỏ luôn việc vá SecItem*.
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>

static NSString *const kLPAppGroupID = @"group.com.locket.Locket-Shared";

// Thư mục thật dùng thay cho app-group (bản ký lại không có entitlement group).
static NSString *LPFallbackGroupPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [[base stringByAppendingPathComponent:@"LPAppGroup"]
                     stringByAppendingPathComponent:kLPAppGroupID];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// Swizzle ObjC — an toàn, không đụng mã máy của hàm hệ thống.
static NSURL *(*gOrigContainerURL)(id, SEL, NSString *);
static NSURL *LPContainerURL(id self, SEL _cmd, NSString *groupID) {
    NSURL *real = gOrigContainerURL ? gOrigContainerURL(self, _cmd, groupID) : nil;
    if (real) return real;                       // máy có entitlement thật → dùng luôn
    if (![groupID isKindOfClass:[NSString class]]) return nil;
    if (![groupID containsString:@"locket"]) return nil;

    NSString *path = LPFallbackGroupPath();
    LPLog(@"[sideload] app-group %@ → %@", groupID, path);
    return [NSURL fileURLWithPath:path isDirectory:YES];
}

void LPInstallSideloadFixes(void) {
    @autoreleasepool {
        Class fm = NSClassFromString(@"NSFileManager");
        SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
        if (LPHookMethod(fm, sel, (IMP)LPContainerURL, (IMP *)&gOrigContainerURL)) {
            LPLog(@"[sideload] swizzle containerURLForSecurityApplicationGroupIdentifier:");
        } else {
            LPLog(@"[sideload] không hook được containerURL (bỏ qua)");
        }
    }
}
