// ============================================================================
//  LPSideload.m — sống sót khi cài sideload
//
//  BÀI HỌC TỪ LOG THẬT:
//   • v1.11 dùng MSHookFunction để vá SecItem* → chết ngay trong constructor.
//   • v1.12 bỏ hết vá keychain → app mở được nhưng MÀN ĐEN + quay mãi ở màn
//     đăng nhập, vì Firebase Auth ghi/đọc phiên trong keychain với
//     kSecAttrAccessGroup của team gốc. Bản ký lại không có group đó →
//     errSecMissingEntitlement → không khôi phục được phiên.
//
//  Cách của blatantsPatch.dylib (bản KHÔNG crash, đăng nhập được):
//   • Tự vá mã máy bằng vm_protect + memcpy (KHÔNG dùng MSHookFunction).
//   • Bỏ kSecAttrAccessGroup khỏi mọi query SecItem*.
//   • Swizzle containerURLForSecurityApplicationGroupIdentifier: trả thư mục thật.
//
//  Ở đây làm đúng như vậy, tự viết trampoline để không phụ thuộc substrate.
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>
#import <Security/Security.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <string.h>
#import <libkern/OSCacheControl.h>

static NSString *const kLPAppGroupID = @"group.com.locket.Locket-Shared";

#pragma mark - inline hook (trampoline, không cần substrate)

// Vá 16 byte đầu hàm bằng: ldr x16,#8 ; br x16 ; .quad <đích>
// Bản gốc được copy sang một trang executable riêng + nhảy về target+16,
// nhờ vậy vẫn gọi được hàm gốc (khác MSHookFunction, cái này không crash).
static int LPInlineHook(void *target, void *replacement, void **origOut) {
    if (!target || !replacement) return 0;

    const int patchLen = 16;
    size_t pageSize = 16384;

    void *tramp = mmap(NULL, pageSize, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
    if (tramp == MAP_FAILED) {
        LPLog(@"[sideload] mmap trampoline thất bại");
        return 0;
    }

    // 1) copy prologue gốc
    memcpy(tramp, target, patchLen);
    // 2) nhảy về target + patchLen
    uint32_t *p = (uint32_t *)((char *)tramp + patchLen);
    p[0] = 0x58000050;                       // ldr x16, #8
    p[1] = 0xD61F0200;                       // br  x16
    *(uint64_t *)(p + 2) = (uint64_t)((char *)target + patchLen);
    sys_icache_invalidate(tramp, pageSize);

    // 3) mở quyền ghi cho trang chứa target rồi vá
    vm_address_t page = (vm_address_t)target & ~(vm_address_t)(pageSize - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, pageSize, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        LPLog(@"[sideload] vm_protect lỗi %d cho %p", kr, target);
        munmap(tramp, pageSize);
        return 0;
    }

    uint32_t *t = (uint32_t *)target;
    t[0] = 0x58000050;
    t[1] = 0xD61F0200;
    *(uint64_t *)(t + 2) = (uint64_t)replacement;
    sys_icache_invalidate(target, patchLen);

    if (origOut) *origOut = tramp;
    return 1;
}

#pragma mark - keychain: bỏ access group sai

// Trả query đã bỏ kSecAttrAccessGroup. Caller phải CFRelease nếu khác bản gốc.
static CFDictionaryRef LPSanitize(CFDictionaryRef query) {
    if (!query) return query;
    if (!CFDictionaryContainsKey(query, kSecAttrAccessGroup)) return query;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (!m) return query;
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    return m;
}

typedef OSStatus (*LPSec2)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*LPSecUpd)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*LPSecDel)(CFDictionaryRef);

static LPSec2 gOrigAdd, gOrigCopy;
static LPSecUpd gOrigUpd;
static LPSecDel gOrigDel;

static OSStatus LPAdd(CFDictionaryRef q, CFTypeRef *res) {
    if (!gOrigAdd) return errSecParam;
    CFDictionaryRef s = LPSanitize(q);
    OSStatus st = gOrigAdd(s, res);
    if (s != q) CFRelease(s);
    return st;
}

static OSStatus LPCopy(CFDictionaryRef q, CFTypeRef *res) {
    if (!gOrigCopy) return errSecParam;
    CFDictionaryRef s = LPSanitize(q);
    OSStatus st = gOrigCopy(s, res);
    if (s != q) CFRelease(s);
    return st;
}

static OSStatus LPUpd(CFDictionaryRef q, CFDictionaryRef attrs) {
    if (!gOrigUpd) return errSecParam;
    CFDictionaryRef s = LPSanitize(q);
    OSStatus st = gOrigUpd(s, attrs);
    if (s != q) CFRelease(s);
    return st;
}

static OSStatus LPDel(CFDictionaryRef q) {
    if (!gOrigDel) return errSecParam;
    CFDictionaryRef s = LPSanitize(q);
    OSStatus st = gOrigDel(s);
    if (s != q) CFRelease(s);
    return st;
}

#pragma mark - app group

// Dùng đúng vị trí chuẩn mà Locket mong đợi (Library/Shared/AppGroup/<id>),
// KHÔNG dùng thư mục tuỳ ý — sai đường dẫn là app không thấy dữ liệu cũ.
static NSString *LPGroupPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *shared = [[base stringByAppendingPathComponent:@"../Shared/AppGroup"]
                        stringByStandardizingPath];
    NSString *dir = [shared stringByAppendingPathComponent:kLPAppGroupID];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSURL *(*gOrigContainerURL)(id, SEL, NSString *);
static NSURL *LPContainerURL(id self, SEL _cmd, NSString *groupID) {
    NSURL *real = gOrigContainerURL ? gOrigContainerURL(self, _cmd, groupID) : nil;
    if (real) return real;                    // có entitlement thật → dùng luôn
    if (![groupID isKindOfClass:[NSString class]]) return nil;
    if (![groupID containsString:@"locket"]) return nil;

    // Hàm này bị gọi HÀNG CHỤC LẦN mỗi giây (Locket hỏi liên tục). Cache lại,
    // nếu không sẽ vừa chậm vừa ngập log. Chỉ tạo thư mục 1 lần.
    static NSURL *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = [NSURL fileURLWithPath:LPGroupPath() isDirectory:YES];
        LPLog(@"[sideload] app-group → %@", cached.path);
    });
    return cached;
}

#pragma mark - install

void LPInstallSideloadFixes(void) {
    @autoreleasepool {
        // 1) keychain — chỉ vá khi thật sự cần (bản ký lại không có group).
        BOOL patched = 0;
        patched += LPInlineHook((void *)SecItemAdd, (void *)LPAdd, (void **)&gOrigAdd);
        patched += LPInlineHook((void *)SecItemCopyMatching, (void *)LPCopy, (void **)&gOrigCopy);
        patched += LPInlineHook((void *)SecItemUpdate, (void *)LPUpd, (void **)&gOrigUpd);
        patched += LPInlineHook((void *)SecItemDelete, (void *)LPDel, (void **)&gOrigDel);
        LPLog(@"[sideload] SecItem*: vá %d/4 hàm", patched);

        // 2) app group container
        Class fm = NSClassFromString(@"NSFileManager");
        SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
        if (LPHookMethod(fm, sel, (IMP)LPContainerURL, (IMP *)&gOrigContainerURL)) {
            LPLog(@"[sideload] swizzle containerURL");
        }
    }
}
