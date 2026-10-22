// ============================================================================
//  LPGold.m — mở khoá Gold phía client (RevenueCat + Remote Config)
//
//  Vì sao phải viết lại (bản LocketPatch.x cũ không chạy được):
//   1. `[self valueForKey:@"key"]` trên FIRRemoteConfigValue → KVC ném
//      NSException vì object chỉ có instance var `_key` (KVC không đọc ivar
//      có gạch dưới). Kết quả: mọi lần đọc boolValue đều vào @catch, key = nil,
//      nhánh friend/badge/gold KHÔNG BAO GIỜ chạy.
//   2. Hook `activeSubscriptions` bằng IMP trả BOOL, nhưng method thật trả
//      NSSet → đọc ra là rác/ crash.
//   3. Hook class Swift ("SubscriptionManager", "UserManager"...) bằng tên
//      ObjC thuần → NSClassFromString luôn nil vì class Swift có tiền tố
//      _TtC<module><len><Tên>. Nên phần "force isGold" chưa bao giờ chạy.
//
//  Bản này: đọc key qua ivar, hook đúng kiểu, và quét class Swift theo tên.
//
//  GIỚI HẠN: đây là UI/client. Server Locket vẫn coi bạn là free →
//  bạn bè khác không thấy badge, và hạn mức kết bạn phía server không đổi.
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>
#import <string.h>
#import <objc/message.h>

static NSString *const kLPEntitlementID = @"Gold";

// Các key Remote Config liên quan tới Gold / hạn mức / tính năng cao cấp.
static NSArray<NSString *> *LPGoldKeys(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[@"gold", @"premium", @"pro_", @"subscri", @"entitlement",
              @"theme", @"camera_theme", @"badge", @"unlimited",
              @"streak_recovery", @"remove_ads", @"longer_video",
              @"priority_support", @"friend_limit", @"max_friends",
              @"video_duration", @"video_size", @"max_video"];
    });
    return a;
}

static BOOL LPKeyUnlocked(NSString *key) {
    if (!key.length) return NO;
    NSString *lk = key.lowercaseString;
    for (NSString *k in LPGoldKeys()) if ([lk containsString:k]) return YES;
    return NO;
}

#pragma mark - đọc key của FIRRemoteConfigValue qua ivar

// KVC không đọc được ivar `_key`, nên phải lấy thẳng từ object layout.
static const char *LPRCIvarKey(id obj) {
    if (!obj) return NULL;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        if (c == [NSObject class]) break;
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *name = ivar_getName(ivs[i]);
            if (!name) continue;
            if (strcmp(name, "_key") == 0 || strcmp(name, "key") == 0 ||
                strcmp(name, "_configKey") == 0) {
                const char *v = *(const char **)((char *)(__bridge void *)obj + ivar_getOffset(ivs[i]));
                free(ivs);
                return v;
            }
        }
        free(ivs);
    }
    return NULL;
}

static NSString *LPRCKeyString(id obj) {
    const char *k = LPRCIvarKey(obj);
    if (!k) return nil;
    return [NSString stringWithUTF8String:k];
}

#pragma mark - hook FIRRemoteConfigValue

static BOOL (*gOrigRCBool)(id, SEL);
static BOOL LPRCBool(id self, SEL _cmd) {
    BOOL real = gOrigRCBool ? gOrigRCBool(self, _cmd) : NO;
    @try {
        if (LPKeyUnlocked(LPRCKeyString(self))) return YES;
    } @catch (__unused NSException *e) {}
    return real;
}

static NSNumber *(*gOrigRCNumber)(id, SEL);
static NSNumber *LPRCNumber(id self, SEL _cmd) {
    NSNumber *real = gOrigRCNumber ? gOrigRCNumber(self, _cmd) : nil;
    @try {
        NSString *k = LPRCKeyString(self);
        if (!k.length) return real;
        NSString *lk = k.lowercaseString;
        // Chỉ nới các key GIỚI HẠN video; không đụng tới số khác của app.
        if ([lk containsString:@"video"] && ([lk containsString:@"duration"] ||
                                             [lk containsString:@"second"] ||
                                             [lk containsString:@"length"])) {
            return @(LPVideoSeconds());
        }
        if ([lk containsString:@"video"] && ([lk containsString:@"size"] ||
                                             [lk containsString:@"bytes"] ||
                                             [lk containsString:@"mb"])) {
            return @(LPVideoBytes());
        }
    } @catch (__unused NSException *e) {}
    return real;
}

static long long (*gOrigRCInt)(id, SEL);
static long long LPRCInt(id self, SEL _cmd) {
    long long real = gOrigRCInt ? gOrigRCInt(self, _cmd) : 0;
    NSNumber *n = LPRCNumber(self, _cmd);
    return n ? (long long)n.longLongValue : real;
}

static NSString *(*gOrigRCString)(id, SEL);
static NSString *LPRCString(id self, SEL _cmd) {
    NSString *real = gOrigRCString ? gOrigRCString(self, _cmd) : nil;
    @try {
        NSString *k = LPRCKeyString(self);
        if (!k.length) return real;
        NSString *lk = k.lowercaseString;
        if ([lk containsString:@"friend"] && [lk containsString:@"limit"]) {
            // "unlimited" là giá trị Locket dùng cho Gold
            return @"unlimited";
        }
        if ([lk containsString:@"video"] && [lk containsString:@"duration"]) {
            return [NSString stringWithFormat:@"%.0f", LPVideoSeconds()];
        }
    } @catch (__unused NSException *e) {}
    return real;
}

#pragma mark - hook RevenueCat CustomerInfo

// RCCustomerInfo.entitlements → NSDictionary<NSString*, RCEntitlementInfo*>
static id (*gOrigCIEntitlements)(id, SEL);
static id LPCIEntitlements(id self, SEL _cmd) {
    id real = gOrigCIEntitlements ? gOrigCIEntitlements(self, _cmd) : nil;
    NSMutableDictionary *d = [real isKindOfClass:[NSDictionary class]] ? [real mutableCopy]
                                                                      : [NSMutableDictionary dictionary];
    // Không tự chế object RCEntitlementInfo (sai class sẽ crash khi app đọc
    // property). Chỉ đảm bảo key "Gold" tồn tại nếu app đã có object thật.
    if (!d[kLPEntitlementID] && d.count) {
        for (NSString *k in d.allKeys) {
            id v = d[k];
            if ([k.lowercaseString containsString:@"gold"] ||
                [k.lowercaseString containsString:@"premium"]) {
                d[kLPEntitlementID] = v;
                break;
            }
        }
    }
    return d;
}

// RCCustomerInfo.activeSubscriptions → NSSet<NSString*>
static id (*gOrigCIActive)(id, SEL);
static id LPCIActiveSubscriptions(id self, SEL _cmd) {
    id real = gOrigCIActive ? gOrigCIActive(self, _cmd) : nil;
    NSMutableSet *s = [real isKindOfClass:[NSSet class]] ? [real mutableCopy] : [NSMutableSet set];
    [s addObject:@"locket_gold_annual"];
    return s;
}

#pragma mark - quét class Swift của app

static NSArray<NSString *> *LPSwiftClassNames(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int count = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * count);
        count = objc_getClassList(classes, count);
        NSMutableArray *a = [NSMutableArray array];
        for (int i = 0; i < count; i++) {
            const char *n = class_getName(classes[i]);
            if (n && strncmp(n, "_TtC", 4) == 0) [a addObject:[NSString stringWithUTF8String:n]];
        }
        free(classes);
        names = a;
    });
    return names;
}

static BOOL LPSwiftNameMatches(NSString *cls, NSArray<NSString *> *kws) {
    NSString *l = cls.lowercaseString;
    for (NSString *k in kws) if ([l containsString:k]) return YES;
    return NO;
}

static BOOL LPBoolTrue(id self, SEL _cmd) { return YES; }

// Chỉ hook những selector mang nghĩa "Gold/订阅 đang bật" — KHÔNG đụng getter
// chung như isActive/isPro trên class lạ (có thể là network client → app hỏng).
static void LPForceGoldGetters(Class cls) {
    if (!cls) return;
    NSArray *sels = @[@"isGold", @"hasGold", @"isGoldMember", @"isPremium",
                      @"hasPremium", @"isSubscribed", @"hasActiveSubscription",
                      @"isLocketGold", @"goldActive"];
    for (NSString *s in sels) {
        SEL sel = NSSelectorFromString(s);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        char ret = method_getTypeEncoding(m)[0];
        if (ret != 'c' && ret != 'B') continue;   // chỉ hook getter trả BOOL
        LPHookMethod(cls, sel, (IMP)LPBoolTrue, NULL);
        LPLog(@"[gold] force %@.%@ → YES", NSStringFromClass(cls), s);
    }
}

static void LPInstallGoldHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class rcVal = NSClassFromString(@"FIRRemoteConfigValue");
        if (!rcVal) rcVal = NSClassFromString(@"RCValue");
        if (rcVal) {
            LPHookMethod(rcVal, @selector(boolValue), (IMP)LPRCBool, (IMP *)&gOrigRCBool);
            LPHookMethod(rcVal, @selector(numberValue), (IMP)LPRCNumber, (IMP *)&gOrigRCNumber);
            LPHookMethod(rcVal, @selector(integerValue), (IMP)LPRCInt, (IMP *)&gOrigRCInt);
            LPHookMethod(rcVal, @selector(stringValue), (IMP)LPRCString, (IMP *)&gOrigRCString);
            LPLog(@"[gold] hook %@ (bool/number/integer/string)", NSStringFromClass(rcVal));
        } else {
            LPLog(@"[gold] KHÔNG có FIRRemoteConfigValue");
        }

        Class ci = NSClassFromString(@"RCCustomerInfo");
        if (ci) {
            LPHookMethod(ci, @selector(entitlements), (IMP)LPCIEntitlements, (IMP *)&gOrigCIEntitlements);
            LPHookMethod(ci, @selector(activeSubscriptions), (IMP)LPCIActiveSubscriptions, (IMP *)&gOrigCIActive);
            LPLog(@"[gold] hook RCCustomerInfo");
        } else {
            LPLog(@"[gold] KHÔNG có RCCustomerInfo");
        }

        // Quét class Swift của app: chỉ những class tên có nghĩa subscription.
        NSArray *kws = @[@"subscription", @"purchase", @"entitlement", @"premium",
                         @"paywall", @"storekit", @"gold"];
        for (NSString *n in LPSwiftClassNames()) {
            if (!LPSwiftNameMatches(n, kws)) continue;
            LPForceGoldGetters(NSClassFromString(n));
        }
        LPLog(@"[gold] xong (client-side)");
    });
}

// Gọi lại sau khi app chạy một lúc: Swift class có thể nạp muộn.
void LPInstallGoldUnlock(void) {
    LPInstallGoldHooks();
    for (int i = 1; i <= 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                NSArray *kws = @[@"subscription", @"purchase", @"entitlement", @"premium",
                                 @"paywall", @"storekit", @"gold"];
                for (NSString *n in LPSwiftClassNames()) {
                    if (LPSwiftNameMatches(n, kws)) LPForceGoldGetters(NSClassFromString(n));
                }
            });
        });
    }
}
