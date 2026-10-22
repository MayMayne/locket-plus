// ============================================================================
//  LPSideload.m — copy nguyên cơ chế blatantsPatch.dylib
//
//  Đã disassemble từng lệnh. Nó làm ĐÚNG 4 việc:
//
//  1. Constructor: tạo keychain canary (generic password, account
//     "blatantsPatch", service "") bằng SecItemCopyMatching → nếu
//     errSecItemNotFound thì SecItemAdd. Đọc lại kSecAttrAccessGroup của nó
//     → đó là access group THẬT sau khi ký lại.
//
//  2. fishhook 4 hàm SecItem* trong __DATA_CONST,__got của main executable.
//     Trước khi ghi gọi vm_protect(mach_task_self(), page, span, false,
//     VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY) — địa chỉ 0x5138-0x5154.
//
//  3. Trong wrapper: CFDictionarySetValue(query, kSecAttrAccessGroup, groupThật)
//     — THAY, không XOÁ. (Xoá → Firebase Auth mất phiên → màn đen, lỗi v1.12/13.)
//
//  4. Swizzle -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]
//     trả thư mục thay thế có thật.
//
//  KHÔNG hook NSUserDefaults. blatantsPatch có hook _initWithSuiteName:container:
//  nhưng nó chỉ có tác dụng khi app group thật sự không tồn tại; containerURL
//  đã xử lý việc đó. Bỏ để giảm bề mặt.
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

    // Số học fishhook: __LINKEDIT ở slide + vmaddr - fileoff.
    uintptr_t lb = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const struct nlist_64 *)(lb + symtab->symoff);
    const char *strtab = (const char *)(lb + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(lb + dysymtab->indirectsymoff);

    p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd != LC_SEGMENT_64) { p += lc->cmdsize; continue; }

        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__DATA_CONST") != 0 &&
            strcmp(seg->segname, "__DATA") != 0) {
            p += lc->cmdsize;
            continue;
        }

        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
            // __got: con trỏ THƯỜNG kể cả trên arm64e (blatantsPatch vá đúng
            // section này). __auth_got: con trỏ ĐÃ KÝ PAC → bỏ qua.
            BOOL got = (strcmp(sect->sectname, "__got") == 0);
            BOOL lazy = (strcmp(sect->sectname, "__la_symbol_ptr") == 0);
            BOOL nonlazy = (strcmp(sect->sectname, "__nl_symbol_ptr") == 0);
            if (!got && !lazy && !nonlazy) continue;
            if (sect->size < sizeof(void *)) continue;

            void **ptrs = (void **)((uintptr_t)slide + sect->addr);
            uint32_t n = (uint32_t)(sect->size / sizeof(void *));

            // __DATA_CONST read-only sau fixup → mprotect trước khi ghi.
            vm_address_t page = (vm_address_t)ptrs & ~(vm_page_size - 1);
            vm_size_t span = (vm_size_t)((uintptr_t)ptrs + sect->size) - page;
            if (vm_protect(mach_task_self(), page, span, false,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
                continue;
            }

            for (uint32_t k = 0; k < n; k++) {
                uint32_t si = indirect[sect->reserved1 + k];
                if (si == INDIRECT_SYMBOL_LOCAL || si == INDIRECT_SYMBOL_ABS) continue;
                if (si >= symtab->nsyms) continue;

                const char *name = strtab + syms[si].n_un.n_strx;
                for (int it = 0; it < count; it++) {
                    if (!items[it].replacement) continue;
                    if (strcmp(name, items[it].name) != 0) continue;
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

// Chỉ vá ảnh trong bundle app. Ảnh trong dyld shared cache có __DATA_CONST
// read-only vĩnh viễn → mprotect fail (đã kiểm ở trên nên không crash).
static BOOL LPIsAppImage(const struct mach_header *mh) {
    Dl_info info;
    if (dladdr((const void *)mh, &info) == 0 || !info.dli_fname) return NO;
    if (!strstr(info.dli_fname, ".app/")) return NO;
    if (strstr(info.dli_fname, "LocketPlus.dylib")) return NO;
    return YES;
}

static void LPRebindAll(LPRebind *items, int count) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || !LPIsAppImage(mh)) continue;
        LPRebindImage((const struct mach_header_64 *)mh,
                      _dyld_get_image_vmaddr_slide(i), items, count);
    }
}

static void LPImageAdded(const struct mach_header *mh, intptr_t slide) {
    if (!mh || !LPIsAppImage(mh)) return;
    LPRebindImage((const struct mach_header_64 *)mh, slide, gRebinds, gRebindCount);
}

#pragma mark - access group thật (canary, đúng như blatantsPatch @0x4000)

static NSString *gRealGroup = nil;

static void LPCreateCanary(void) {
    NSDictionary *q = @{
        (__bridge id)kSecClass:             (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount:       @"blatantsPatch",
        (__bridge id)kSecAttrService:       @"",
        (__bridge id)kSecReturnAttributes:  @YES,
        (__bridge id)kSecMatchLimit:        (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef res = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
    if (st == errSecItemNotFound) {
        OSStatus add = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
        if (add == errSecSuccess || add == errSecDuplicateItem) {
            if (res) { CFRelease(res); res = NULL; }
            st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        } else {
            LPLog(@"[sideload] canary add lỗi %d", (int)add);
        }
    }

    if (st == errSecSuccess && res) {
        NSDictionary *attrs = (__bridge_transfer NSDictionary *)res;
        id g = attrs[(__bridge id)kSecAttrAccessGroup];
        if ([g isKindOfClass:[NSString class]] && [g length]) {
            gRealGroup = [g copy];
            LPLog(@"[sideload] access group: %@", gRealGroup);
        }
    } else if (res) {
        CFRelease(res);
    }

    if (!gRealGroup.length) {
        // Fallback: bản ký cert cá nhân dùng bundle id làm group.
        NSString *bid = [NSBundle mainBundle].bundleIdentifier;
        gRealGroup = bid.length ? bid : @"com.locket.Locket";
        LPLog(@"[sideload] access group fallback: %@", gRealGroup);
    }
}

#pragma mark - SecItem* wrappers (THAY group, không xoá)

typedef OSStatus (*LPSec2)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*LPSecUpd)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*LPSecDel)(CFDictionaryRef);

static LPSec2   gOrigAdd  = NULL;
static LPSec2   gOrigCopy = NULL;
static LPSecUpd gOrigUpd  = NULL;
static LPSecDel gOrigDel  = NULL;

static CFDictionaryRef LPFix(CFDictionaryRef query) {
    if (!query || !gRealGroup.length) return NULL;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, query);
    if (!m) return NULL;
    CFDictionarySetValue(m, kSecAttrAccessGroup, (__bridge CFStringRef)gRealGroup);
    return m;
}

static OSStatus LPAdd(CFDictionaryRef q, CFTypeRef *r) {
    if (!gOrigAdd) return errSecParam;
    CFDictionaryRef s = LPFix(q);
    OSStatus st = gOrigAdd(s ?: q, r);
    if (s) CFRelease(s);
    return st;
}

static OSStatus LPCopy(CFDictionaryRef q, CFTypeRef *r) {
    if (!gOrigCopy) return errSecParam;
    CFDictionaryRef s = LPFix(q);
    OSStatus st = gOrigCopy(s ?: q, r);
    if (s) CFRelease(s);
    return st;
}

static OSStatus LPUpd(CFDictionaryRef q, CFDictionaryRef a) {
    if (!gOrigUpd) return errSecParam;
    CFDictionaryRef s = LPFix(q);
    OSStatus st = gOrigUpd(s ?: q, a);
    if (s) CFRelease(s);
    return st;
}

static OSStatus LPDel(CFDictionaryRef q) {
    if (!gOrigDel) return errSecParam;
    CFDictionaryRef s = LPFix(q);
    OSStatus st = gOrigDel(s ?: q);
    if (s) CFRelease(s);
    return st;
}

#pragma mark - app group container

static NSURL *(*gOrigContainer)(id, SEL, NSString *);

static NSURL *LPContainer(id self, SEL _cmd, NSString *groupID) {
    NSURL *real = gOrigContainer ? gOrigContainer(self, _cmd, groupID) : nil;
    if (real) return real;
    if (![groupID isKindOfClass:[NSString class]] || !groupID.length) return nil;
    if (![groupID.lowercaseString containsString:@"locket"]) return nil;

    NSString *path = LPGroupPathFor(groupID);
    if (!path.length) return nil;

    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });

    @synchronized (cache) {
        NSURL *u = cache[groupID];
        if (!u) {
            u = [NSURL fileURLWithPath:path isDirectory:YES];
            cache[groupID] = u;
            LPLog(@"[sideload] app-group → %@", path);
        }
        return u;
    }
}

#pragma mark - install

void LPInstallSideloadFixes(void) {
    @autoreleasepool {
        // Canary TRƯỚC khi hook (nếu không, query của canary bị wrapper sửa).
        LPCreateCanary();

        gRebinds[0].replacement = (void *)LPAdd;   gRebinds[0].original = (void **)&gOrigAdd;
        gRebinds[1].replacement = (void *)LPCopy;  gRebinds[1].original = (void **)&gOrigCopy;
        gRebinds[2].replacement = (void *)LPUpd;   gRebinds[2].original = (void **)&gOrigUpd;
        gRebinds[3].replacement = (void *)LPDel;   gRebinds[3].original = (void **)&gOrigDel;

        LPRebindAll(gRebinds, gRebindCount);
        _dyld_register_func_for_add_image(LPImageAdded);
        LPLog(@"[sideload] fishhook: add=%p copy=%p", gOrigAdd, gOrigCopy);

        Class fm = NSClassFromString(@"NSFileManager");
        if (LPHookMethod(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:),
                         (IMP)LPContainer, (IMP *)&gOrigContainer)) {
            LPLog(@"[sideload] swizzle containerURL");
        }
    }
}
