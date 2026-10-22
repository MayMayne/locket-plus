// ============================================================================
//  LPSideload.m — sống sót khi cài sideload
//
//  Viết lại theo ĐÚNG những gì blatantsPatch.dylib làm (đã disassemble):
//
//  1. Hook bằng FISHHOOK, không phải MSHookFunction và không phải vm_protect.
//     Fishhook sửa __la_symbol_ptr trong __LINKEDIT — không đụng mã máy của
//     hàm hệ thống, nên không bao giờ chết trong constructor.
//     (MSHookFunction vá mã máy trong dyld shared cache → crash ngay.)
//
//  2. KHÔNG xoá kSecAttrAccessGroup. Đọc access group THẬT của app hiện tại
//     rồi THAY vào query. Xoá đi thì Firebase Auth không tìm thấy item cũ
//     → màn đen + quay mãi ở màn đăng nhập.
//
//  3. Swizzle containerURLForSecurityApplicationGroupIdentifier: (ObjC).
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <string.h>

static NSString *const kLPAppGroupID = @"group.com.locket.Locket-Shared";

#pragma mark - fishhook (tự viết, không cần thư viện ngoài)

// Cấu trúc một lần rebind: tên symbol + con trỏ thay thế + nơi lưu bản gốc.
typedef struct {
    const char *name;
    void       *replacement;
    void      **original;
} LPRebind;

// Sửa mọi con trỏ lazy/non-lazy binding trỏ tới `name` trong image đang nạp.
static void LPRebindImage(const struct mach_header_64 *mh, intptr_t slide,
                          LPRebind *items, int count) {
    if (!mh || mh->magic != MH_MAGIC_64) return;

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;

    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__LINKEDIT") == 0) linkedit = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)lc;
        }
        p += lc->cmdsize;
    }
    if (!linkedit || !symtab || !dysymtab) return;

    const uint8_t *base = (const uint8_t *)mh;
    const char *strtab = (const char *)(base + slide + symtab->stroff);
    const struct nlist_64 *syms = (const struct nlist_64 *)(base + slide + symtab->symoff);

    // Quét các section chứa con trỏ binding.
    p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            const struct section_64 *sect = (const struct section_64 *)(seg + 1);
            for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
                // Chỉ 2 loại section chứa con trỏ cần sửa.
                BOOL lazy = (strcmp(sect->sectname, "__la_symbol_ptr") == 0);
                BOOL nonlazy = (strcmp(sect->sectname, "__nl_symbol_ptr") == 0);
                if (!lazy && !nonlazy) continue;

                void **ptrs = (void **)(base + slide + sect->offset);
                uint32_t n = sect->size / sizeof(void *);
                const uint32_t *indirect =
                    (const uint32_t *)(base + slide + dysymtab->indirectsymoff);
                for (uint32_t k = 0; k < n; k++) {
                    // reserved1 = vị trí bắt đầu của section trong bảng indirect.
                    uint32_t symIndex = indirect[sect->reserved1 + k];
                    if (symIndex == INDIRECT_SYMBOL_LOCAL ||
                        symIndex == INDIRECT_SYMBOL_ABS) continue;
                    if (symIndex >= symtab->nsyms) continue;

                    const char *symName = strtab + syms[symIndex].n_un.n_strx;
                    for (int it = 0; it < count; it++) {
                        if (strcmp(symName, items[it].name) != 0) continue;
                        if (items[it].original && !*items[it].original) {
                            *items[it].original = ptrs[k];
                        }
                        // Chỉ ghi khi con trỏ đang trỏ tới stub gốc.
                        ptrs[k] = items[it].replacement;
                        break;
                    }
                }
            }
        }
        p += lc->cmdsize;
    }
}

static void LPRebindAll(LPRebind *items, int count) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (mh && mh->filetype == MH_EXECUTE) {
            LPRebindImage((const struct mach_header_64 *)mh, slide, items, count);
        }
    }
}

typedef OSStatus (*LPSec2)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*LPSecUpd)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*LPSecDel)(CFDictionaryRef);

static LPSec2 gOrigAdd, gOrigCopy;
static LPSecUpd gOrigUpd;
static LPSecDel gOrigDel;

#pragma mark - access group thật của app

// Access group thật = "<teamID>.<bundleID>". Trên bản sideload team ID là của
// người ký lại, nên phải đọc động chứ không hardcode.
static NSString *LPRealAccessGroup(void) {
    static NSString *group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Cách 1: entitlements của app (chính xác nhất).
        NSBundle *b = [NSBundle mainBundle];
        NSDictionary *ent = nil;
        @try {
            ent = [b objectForInfoDictionaryKey:@"entitlements"];
        } @catch (__unused NSException *e) {}

        // Cách 2: hỏi thẳng Security xem app có group nào.
        if (!ent) {
            NSDictionary *q = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                (__bridge id)kSecReturnAttributes: @YES,
                                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
            CFTypeRef res = NULL;
            // Dùng IMP GỐC: SecItemCopyMatching đã bị hook → gọi lại là đệ quy vô hạn.
            OSStatus st = gOrigCopy ? gOrigCopy((__bridge CFDictionaryRef)q, &res) : errSecParam;
            if (st == errSecSuccess && res) {
                NSDictionary *attrs = (__bridge_transfer NSDictionary *)res;
                id g = attrs[(__bridge id)kSecAttrAccessGroup];
                if ([g isKindOfClass:[NSString class]]) group = g;
            }
        }

        if (!group.length) {
            // Cách 3: dựng theo bundle id — đúng với app ký bằng cert cá nhân.
            NSString *bid = b.bundleIdentifier ?: @"com.locket.Locket";
            group = bid;   // không có team id thì dùng chính bundle id
        }
        LPLog(@"[sideload] access group thật: %@", group);
    });
    return group;
}

#pragma mark - SecItem* wrappers

// THAY access group, không xoá. Xoá → Firebase Auth mất phiên → màn đen.
static CFDictionaryRef LPFixQuery(CFDictionaryRef query) {
    if (!query) return query;
    NSString *real = LPRealAccessGroup();
    if (!real.length) return query;

    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (!m) return query;
    CFDictionarySetValue(m, kSecAttrAccessGroup, (__bridge CFStringRef)real);
    return m;   // caller phải CFRelease
}

static OSStatus LPAdd(CFDictionaryRef q, CFTypeRef *res) {
    if (!gOrigAdd) return errSecParam;
    CFDictionaryRef s = LPFixQuery(q);
    OSStatus st = gOrigAdd(s, res);
    if (s != q) CFRelease(s);
    return st;
}

static OSStatus LPCopy(CFDictionaryRef q, CFTypeRef *res) {
    if (!gOrigCopy) return errSecParam;
    CFDictionaryRef s = LPFixQuery(q);
    OSStatus st = gOrigCopy(s, res);
    if (s != q) CFRelease(s);
    return st;
}

static OSStatus LPUpd(CFDictionaryRef q, CFDictionaryRef attrs) {
    if (!gOrigUpd) return errSecParam;
    CFDictionaryRef s = LPFixQuery(q);
    OSStatus st = gOrigUpd(s, attrs);
    if (s != q) CFRelease(s);
    return st;
}

static OSStatus LPDel(CFDictionaryRef q) {
    if (!gOrigDel) return errSecParam;
    CFDictionaryRef s = LPFixQuery(q);
    OSStatus st = gOrigDel(s);
    if (s != q) CFRelease(s);
    return st;
}

#pragma mark - app group container

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
    if (real) return real;
    if (![groupID isKindOfClass:[NSString class]]) return nil;
    if (![groupID containsString:@"locket"]) return nil;

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
        // Fishhook: sửa con trỏ binding, KHÔNG vá mã máy → an toàn trong constructor.
        static LPRebind items[] = {
            {"_SecItemAdd",          (void *)LPAdd,  (void **)&gOrigAdd},
            {"_SecItemCopyMatching", (void *)LPCopy, (void **)&gOrigCopy},
            {"_SecItemUpdate",       (void *)LPUpd,  (void **)&gOrigUpd},
            {"_SecItemDelete",       (void *)LPDel,  (void **)&gOrigDel},
        };
        LPRebindAll(items, 4);
        LPLog(@"[sideload] fishhook SecItem*: add=%p copy=%p upd=%p del=%p",
              gOrigAdd, gOrigCopy, gOrigUpd, gOrigDel);

        Class fm = NSClassFromString(@"NSFileManager");
        SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
        if (LPHookMethod(fm, sel, (IMP)LPContainerURL, (IMP *)&gOrigContainerURL)) {
            LPLog(@"[sideload] swizzle containerURL");
        }
    }
}
