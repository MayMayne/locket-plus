// ============================================================================
//  LPSideload.m — sống sót khi cài sideload
//
//  Bám sát blatantsPatch.dylib, từng bước đã đối chiếu assembly:
//
//  @0x4000 (constructor):
//    1. Dựng query { kSecClass: kSecClassGenericPassword,
//                    kSecAttrAccount: "blatantsPatch",
//                    kSecAttrService: "",
//                    kSecReturnAttributes: true }
//    2. SecItemCopyMatching → nếu trả -25300 (errSecItemNotFound) thì SecItemAdd
//    3. Đọc lại thuộc tính kSecAttrAccessGroup của item đó
//       → đó là access group THẬT của bản ký lại
//    4. rebindSecFuncs()  (fishhook 4 hàm SecItem*)
//
//  @0x4a60 (wrapper SecItem): CFDictionaryCreateMutableCopy(query) rồi
//  CFDictionarySetValue(m, kSecAttrAccessGroup, groupThật) — THAY, không XOÁ.
//  Xoá là sai: query rơi về group mặc định, Firebase Auth không thấy item cũ
//  → màn đen + quay mãi ở đăng nhập (đúng lỗi v1.12/v1.13 của mình).
//
//  VÌ SAO KHÔNG MSHookFunction: nó vá mã máy của hàm trong dyld shared cache.
//  iOS 15+ giết process ngay trong constructor. Fishhook chỉ sửa bảng con trỏ
//  trong __got/__la_symbol_ptr của ảnh nằm trong bundle app → không đụng mã máy.
//
//  BẰNG CHỨNG fishhook của blatantsPatch: binary import _vm_protect +
//  _mach_task_self_ và gọi vm_protect(0x13 = R|W|COPY) trước khi ghi; đọc
//  __LINKEDIT → LC_SYMTAB → LC_DYSYMTAB → indirectsymoff; quét section
//  __la_symbol_ptr / __nl_symbol_ptr. Ta quét thêm __got (bản mẫu dùng
//  __DATA_CONST,__got 44 entry) và BỎ QUA __auth_got (con trỏ PAC arm64e).
// ============================================================================

#import "LPCommon.h"
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <mach/vm_page_size.h>
#import <dlfcn.h>
#import <string.h>

#pragma mark - fishhook

typedef struct {
    const char *name;
    void       *replacement;
    void      **original;
} LPRebind;

static LPRebind gRebinds[] = {
    { "_SecItemAdd",          NULL, NULL },
    { "_SecItemCopyMatching", NULL, NULL },
    { "_SecItemUpdate",       NULL, NULL },
    { "_SecItemDelete",       NULL, NULL },
};
static const int gRebindCount = 4;

static void LPRebindImage(const struct mach_header_64 *mh, intptr_t slide,
                          LPRebind *items, int count) {
    if (!mh || mh->magic != MH_MAGIC_64) return;

    const struct segment_command_64 *linkeditSeg = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;

    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, "__LINKEDIT") == 0) linkeditSeg = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)lc;
        }
        p += lc->cmdsize;
    }
    if (!linkeditSeg || !symtab || !dysymtab) return;

    // Số học ĐÚNG: __LINKEDIT nằm ở slide + vmaddr - fileoff.
    // KHÔNG dùng (header + slide) — header đã là địa chỉ runtime, cộng slide
    // lần nữa là ghi vào vùng nhớ rác.
    uintptr_t linkeditBase = (uintptr_t)slide + linkeditSeg->vmaddr - linkeditSeg->fileoff;

    const struct nlist_64 *syms = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strtab = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff);

    p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd != LC_SEGMENT_64) { p += lc->cmdsize; continue; }

        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__DATA") != 0 &&
            strcmp(seg->segname, "__DATA_CONST") != 0 &&
            strcmp(seg->segname, "__AUTH_CONST") != 0) {
            p += lc->cmdsize;
            continue;
        }

        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            BOOL isLazy = (strcmp(sect->sectname, "__la_symbol_ptr") == 0);
            BOOL isLegacy = (strcmp(sect->sectname, "__nl_symbol_ptr") == 0);
            BOOL isGot = (strcmp(sect->sectname, "__got") == 0);
            BOOL isAuthGot = (strcmp(sect->sectname, "__auth_got") == 0);

            if (isAuthGot) continue;      // con trỏ ĐÃ KÝ PAC trên arm64e
            if (!isLazy && !isLegacy && !isGot) continue;
            if (sect->size < sizeof(void *)) continue;

            void **ptrs = (void **)((uintptr_t)slide + sect->addr);
            uint32_t n = (uint32_t)(sect->size / sizeof(void *));

            // __DATA_CONST bị dyld chuyển read-only sau fixup. Phải mprotect
            // lại trang trước khi ghi, nếu không là KERN_PROTECTION_FAILURE.
            // Đây KHÔNG phải vá mã máy — chỉ đổi quyền ghi của trang dữ liệu.
            vm_address_t page = (vm_address_t)ptrs & ~(vm_page_size - 1);
            vm_size_t span = (vm_size_t)((uintptr_t)ptrs + sect->size) - page;
            kern_return_t kr = vm_protect(mach_task_self(), page, span, false,
                                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr != KERN_SUCCESS) continue;

            for (uint32_t k = 0; k < n; k++) {
                uint32_t symIndex = indirect[sect->reserved1 + k];
                if (symIndex == INDIRECT_SYMBOL_LOCAL ||
                    symIndex == INDIRECT_SYMBOL_ABS) continue;
                if (symIndex >= symtab->nsyms) continue;

                const char *symName = strtab + syms[symIndex].n_un.n_strx;
                for (int it = 0; it < count; it++) {
                    if (!items[it].replacement) continue;
                    if (strcmp(symName, items[it].name) != 0) continue;
                    if (items[it].original && !*items[it].original) {
                        *items[it].original = ptrs[k];
                    }
                    ptrs[k] = items[it].replacement;
                    break;
                }
            }
        }
        p += lc->cmdsize;
    }
}

// Chỉ vá ảnh nằm TRONG bundle app (main executable + Frameworks/).
// Ảnh trong dyld shared cache (/usr/lib, /System) có __DATA_CONST read-only
// sau fixup → ghi vào là crash.
static BOOL LPImageIsOurs(const struct mach_header *mh) {
    Dl_info info;
    if (dladdr((const void *)mh, &info) == 0 || !info.dli_fname) return NO;
    if (strstr(info.dli_fname, ".app/") == NULL) return NO;
    if (strstr(info.dli_fname, "LocketPlus.dylib") != NULL) return NO;
    return YES;
}

static void LPRebindAllImages(LPRebind *items, int count) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (!mh || !LPImageIsOurs(mh)) continue;
        LPRebindImage((const struct mach_header_64 *)mh, slide, items, count);
    }
}

static void LPImageAdded(const struct mach_header *mh, intptr_t slide) {
    if (!mh || !LPImageIsOurs(mh)) return;
    LPRebindImage((const struct mach_header_64 *)mh, slide, gRebinds, gRebindCount);
}

#pragma mark - access group thật (canary)

static NSString *gRealGroup = nil;
static NSString *gFallbackGroup = nil;

static NSString *LPBundleID(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    return bid.length ? bid : @"com.locket.Locket";
}

// Chạy TRƯỚC khi cài fishhook — nếu không canary sẽ bị wrapper sửa query.
static void LPCreateCanaryAndReadGroup(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass:             (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount:       @"blatantsPatch",
        (__bridge id)kSecAttrService:       @"",
        (__bridge id)kSecReturnAttributes:  @YES,
        (__bridge id)kSecMatchLimit:        (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st == errSecItemNotFound) {
        OSStatus add = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        if (add == errSecSuccess || add == errSecDuplicateItem) {
            if (result) { CFRelease(result); result = NULL; }
            st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        } else {
            LPLog(@"[sideload] tạo canary lỗi: %d", (int)add);
        }
    }

    if (st == errSecSuccess && result) {
        NSDictionary *attrs = (__bridge_transfer NSDictionary *)result;
        id g = attrs[(__bridge id)kSecAttrAccessGroup];
        if ([g isKindOfClass:[NSString class]] && [g length]) {
            gRealGroup = [g copy];
            LPLog(@"[sideload] access group thật: %@", gRealGroup);
        }
    } else {
        if (result) CFRelease(result);
        LPLog(@"[sideload] không đọc được canary (status %d)", (int)st);
    }

    if (!gRealGroup.length) {
        gFallbackGroup = LPBundleID();
        LPLog(@"[sideload] access group fallback: %@", gFallbackGroup);
    }
}

static NSString *LPRealGroup(void) {
    return gRealGroup.length ? gRealGroup : gFallbackGroup;
}

#pragma mark - SecItem* wrappers

typedef OSStatus (*LPSec2)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*LPSecUpd)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*LPSecDel)(CFDictionaryRef);

static LPSec2   gOrigAdd  = NULL;
static LPSec2   gOrigCopy = NULL;
static LPSecUpd gOrigUpd  = NULL;
static LPSecDel gOrigDel  = NULL;

// THAY access group, KHÔNG xoá. Caller CFRelease.
static CFDictionaryRef LPFixQuery(CFDictionaryRef query) {
    if (!query) return NULL;
    NSString *real = LPRealGroup();
    if (!real.length) return NULL;

    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (!m) return NULL;
    CFDictionarySetValue(m, kSecAttrAccessGroup, (__bridge CFStringRef)real);
    return m;
}

static OSStatus LPAdd(CFDictionaryRef q, CFTypeRef *res) {
    if (!gOrigAdd) return errSecParam;
    CFDictionaryRef s = LPFixQuery(q);
    OSStatus st = gOrigAdd(s ?: q, res);
    if (s) CFRelease(s);
    return st;
}

static OSStatus LPCopy(CFDictionaryRef q, CFTypeRef *res) {
    if (!gOrigCopy) return errSecParam;
    CFDictionaryRef s = LPFixQuery(q);
    OSStatus st = gOrigCopy(s ?: q, res);
    if (s) CFRelease(s);
    return st;
}

static OSStatus LPUpd(CFDictionaryRef q, CFDictionaryRef attrs) {
    if (!gOrigUpd) return errSecParam;
    CFDictionaryRef s = LPFixQuery(q);
    OSStatus st = gOrigUpd(s ?: q, attrs);
    if (s) CFRelease(s);
    return st;
}

static OSStatus LPDel(CFDictionaryRef q) {
    if (!gOrigDel) return errSecParam;
    CFDictionaryRef s = LPFixQuery(q);
    OSStatus st = gOrigDel(s ?: q);
    if (s) CFRelease(s);
    return st;
}

#pragma mark - app group container

static NSURL *(*gOrigContainer)(id, SEL, NSString *);

static NSURL *LPContainerURL(id self, SEL _cmd, NSString *groupID) {
    NSURL *real = gOrigContainer ? gOrigContainer(self, _cmd, groupID) : nil;
    if (real) return real;
    if (![groupID isKindOfClass:[NSString class]] || !groupID.length) return nil;

    // Chỉ thay cho group của Locket — không đụng group của Firebase/Google.
    if (![groupID.lowercaseString containsString:@"locket"]) return nil;

    NSString *path = LPGroupPathFor(groupID);
    if (!path.length) return nil;

    static NSMutableDictionary<NSString *, NSURL *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });

    @synchronized (cache) {
        NSURL *u = cache[groupID];
        if (!u) {
            u = [NSURL fileURLWithPath:path isDirectory:YES];
            cache[groupID] = u;
            LPLog(@"[sideload] app-group %@ → %@", groupID, path);
        }
        return u;
    }
}

#pragma mark - NSUserDefaults suite

// blatantsPatch hook ĐÚNG selector private `_initWithSuiteName:container:`
// (không phải `initWithSuiteName:`).
//
// Private init này nhận thêm container; nếu container không tồn tại (app group
// chưa có khi sideload) thì nó trả nil → mọi lần đọc/ghi defaults của app đi
// vào hư không và có đường dẫn tới crash.
//
// Cách của mẫu: thay container bằng thư mục thay thế có thật, rồi gọi init gốc.
// KHÔNG trả standardUserDefaults — làm vậy là trộn dữ liệu app với app group,
// và trả về object khác class mà caller mong đợi.
static id (*gOrigSuiteContainer)(id, SEL, NSString *, id);

static id LPInitSuiteContainer(id self, SEL _cmd, NSString *suite, id container) {
    if (!gOrigSuiteContainer) return nil;

    // Thử nguyên bản trước — app group có thật thì không can thiệp.
    id r = gOrigSuiteContainer(self, _cmd, suite, container);
    if (r) return r;

    NSString *groupID = nil;
    if ([suite isKindOfClass:[NSString class]] && [suite containsString:@"locket"]) {
        groupID = suite;
    } else if ([container isKindOfClass:[NSString class]] &&
               [container containsString:@"locket"]) {
        groupID = container;
    }
    if (!groupID.length) return nil;

    NSString *path = LPGroupPathFor(groupID);
    if (!path.length) return nil;

    LPLog(@"[sideload] suite %@ container nil → %@", suite, path);
    return gOrigSuiteContainer(self, _cmd, suite, path);
}

#pragma mark - install

void LPInstallSideloadFixes(void) {
    if (![[LPConfig shared] flag:@"sideloadFix" fallback:YES]) {
        LPLog(@"[sideload] tắt theo config");
        return;
    }
    @autoreleasepool {
        // 1) Canary TRƯỚC khi hook.
        LPCreateCanaryAndReadGroup();

        // 2) Fishhook SecItem*.
        gRebinds[0].replacement = (void *)LPAdd;   gRebinds[0].original = (void **)&gOrigAdd;
        gRebinds[1].replacement = (void *)LPCopy;  gRebinds[1].original = (void **)&gOrigCopy;
        gRebinds[2].replacement = (void *)LPUpd;   gRebinds[2].original = (void **)&gOrigUpd;
        gRebinds[3].replacement = (void *)LPDel;   gRebinds[3].original = (void **)&gOrigDel;

        LPRebindAllImages(gRebinds, gRebindCount);
        _dyld_register_func_for_add_image(LPImageAdded);

        LPLog(@"[sideload] fishhook: add=%p copy=%p upd=%p del=%p",
              gOrigAdd, gOrigCopy, gOrigUpd, gOrigDel);

        // 3) App group container.
        Class fm = NSClassFromString(@"NSFileManager");
        if (LPHookMethod(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:),
                         (IMP)LPContainerURL, (IMP *)&gOrigContainer)) {
            LPLog(@"[sideload] swizzle containerURL");
        }

        // 4) NSUserDefaults suite (private init — đúng như blatantsPatch).
        Class ud = NSClassFromString(@"NSUserDefaults");
        SEL suiteSel = NSSelectorFromString(@"_initWithSuiteName:container:");
        if (LPHookMethodTyped(ud, suiteSel, "@", (IMP)LPInitSuiteContainer,
                              (IMP *)&gOrigSuiteContainer)) {
            LPLog(@"[sideload] swizzle _initWithSuiteName:container:");
        }
    }
}
