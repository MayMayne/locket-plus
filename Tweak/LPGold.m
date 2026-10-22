// ============================================================================
//  LPGold.m — mở khoá Gold phía client
//
//  BÁM SÁT AutoRcSideload.dylib (đã disassemble):
//
//  Nó KHÔNG hook RCCustomerInfo / RCEntitlementInfos. Nó chèn một processor
//  vào tầng mạng: khi response là JSON của RevenueCat
//  (api.revenuecat.com/v1/subscribers/... hoặc /v1/receipts), nó REWRITE body
//  để thêm entitlement + subscription còn hạn. Sau đó RevenueCat SDK tự parse
//  ra CustomerInfo "có Gold" — mọi gate của app mở, không cần hook class nào.
//
//  Ưu điểm so với hook class (cách cũ, đã gây crash):
//    • Không phụ thuộc tên class Swift/ObjC của RevenueCat (đổi version vẫn chạy)
//    • Không sai kiểu trả về → không "unrecognized selector"
//    • Chỉ đụng response của đúng host RevenueCat
//
//  GIỚI HẠN THẬT: server Locket vẫn coi bạn là free. Badge trên profile người
//  khác KHÔNG hiện, hạn mức kết bạn phía server KHÔNG đổi. Đây là UI/client.
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>
#import <string.h>

// Entitlement ID Locket dùng (đọc từ binary 2.68: "Gold", "locket_gold").
static NSArray<NSString *> *LPGoldEntitlementIDs(void) {
    return @[@"Gold", @"gold", @"premium", @"locket_gold", @"pro"];
}

// Product ID để nhét vào active_subscriptions / subscriptions.
static NSArray<NSString *> *LPGoldProductIDs(void) {
    return @[@"locket_gold_monthly", @"locket_gold_annual", @"locket_gold_yearly",
             @"com.locket.Locket.gold.monthly", @"com.locket.Locket.gold.annual"];
}

#pragma mark - nhận diện response RevenueCat

static BOOL LPIsRevenueCatURL(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"api.revenuecat.com"]) return YES;
    if ([host hasSuffix:@".revenuecat.com"]) return YES;
    return NO;
}

// Chỉ sửa 2 endpoint này. /v1/offerings, /v1/products KHÔNG sửa —
// offerings phải giữ nguyên để app hiển thị đúng giá, và products không
// chứa entitlement.
static BOOL LPIsSubscriberEndpoint(NSString *path) {
    NSString *p = path.lowercaseString ?: @"";
    if ([p containsString:@"/v1/subscribers/"]) return YES;
    if ([p containsString:@"/v1/receipts"]) return YES;
    return NO;
}

#pragma mark - dựng JSON giả

static NSString *LPIsoNow(void) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    });
    return [df stringFromDate:[NSDate date]];
}

static NSString *LPIsoFuture(void) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    });
    // 10 năm — đủ để app không tự hết hạn trong lúc dùng.
    NSDate *d = [NSDate dateWithTimeIntervalSinceNow:10 * 365 * 24 * 3600];
    return [df stringFromDate:d];
}

static NSDictionary *LPFakeEntitlement(void) {
    return @{
        @"expires_date"     : LPIsoFuture(),
        @"product_identifier": @"locket_gold_annual",
        @"purchase_date"    : LPIsoNow()
    };
}

static NSDictionary *LPFakeSubscription(void) {
    return @{
        @"billing_issues_detected_at": [NSNull null],
        @"expires_date"              : LPIsoFuture(),
        @"is_sandbox"                : @NO,
        @"original_purchase_date"    : LPIsoNow(),
        @"period_type"               : @"normal",
        @"purchase_date"             : LPIsoNow(),
        @"store"                     : @"app_store",
        @"unsubscribe_detected_at"   : [NSNull null]
    };
}

// Sửa một object "subscriber" của RevenueCat: thêm entitlements + subscriptions.
static NSDictionary *LPPatchSubscriber(NSDictionary *sub) {
    if (![sub isKindOfClass:[NSDictionary class]]) return sub;
    NSMutableDictionary *m = [sub mutableCopy];

    NSMutableDictionary *ents = [NSMutableDictionary dictionary];
    id existing = m[@"entitlements"];
    if ([existing isKindOfClass:[NSDictionary class]]) [ents addEntriesFromDictionary:existing];

    // Không ghi đè entitlement đã có (nếu user mua thật thì giữ nguyên).
    BOOL hasGold = NO;
    for (NSString *k in ents.allKeys) {
        NSString *lk = k.lowercaseString;
        if ([lk containsString:@"gold"] || [lk containsString:@"premium"] ||
            [lk containsString:@"pro"]) {
            hasGold = YES;
            break;
        }
    }
    if (!hasGold) {
        for (NSString *eid in LPGoldEntitlementIDs()) {
            if (!ents[eid]) ents[eid] = LPFakeEntitlement();
        }
    }
    m[@"entitlements"] = ents;

    NSMutableDictionary *subs = [NSMutableDictionary dictionary];
    id exSubs = m[@"subscriptions"];
    if ([exSubs isKindOfClass:[NSDictionary class]]) [subs addEntriesFromDictionary:exSubs];
    if (!subs.count) {
        for (NSString *pid in LPGoldProductIDs()) subs[pid] = LPFakeSubscription();
    }
    m[@"subscriptions"] = subs;

    // Một số gate của Locket đọc trực tiếp các cờ này.
    m[@"management_url"] = [NSNull null];
    if (!m[@"original_app_user_id"]) m[@"original_app_user_id"] = @"$RCAnonymousID:locketplus";
    if (!m[@"first_seen"]) m[@"first_seen"] = LPIsoNow();
    if (!m[@"last_seen"]) m[@"last_seen"] = LPIsoNow();

    return m;
}

// Đệ quy tìm mọi key "subscriber" trong JSON và vá.
static id LPPatchJSON(id obj, int depth) {
    if (depth > 12 || !obj) return obj;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        for (id k in obj) {
            id v = obj[k];
            if ([k isKindOfClass:[NSString class]] && [k isEqualToString:@"subscriber"]) {
                m[k] = LPPatchSubscriber(v);
            } else {
                m[k] = LPPatchJSON(v, depth + 1);
            }
        }
        return m;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id v in obj) [a addObject:LPPatchJSON(v, depth + 1)];
        return a;
    }
    return obj;
}

#pragma mark - processor

static void LPGoldProcessor(NSURLRequest *req, LPNetResult *res) {
    if (![[LPConfig shared] flag:@"goldUnlock" fallback:YES]) return;
    if (!res || !res.data.length) return;
    if (!LPIsRevenueCatURL(req.URL)) return;
    if (!LPIsSubscriberEndpoint(req.URL.path)) return;

    NSInteger code = [(NSHTTPURLResponse *)res.response statusCode];
    if (code != 200 && code != 201) return;

    // Chỉ xử lý JSON (RevenueCat có thể trả gzip đã được URLSession giải nén sẵn).
    id json = [NSJSONSerialization JSONObjectWithData:res.data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) return;

    id patched = LPPatchJSON(json, 0);
    NSData *out = [NSJSONSerialization dataWithJSONObject:patched options:0 error:NULL];
    if (!out.length) return;

    res.data = out;
    LPLog(@"[gold] vá response %@ (%lu byte)", req.URL.path, (unsigned long)out.length);
}

void LPInstallGoldNetProcessor(void) {
    LPAddNetProcessor(^(NSURLRequest *req, LPNetResult *res) {
        @try { LPGoldProcessor(req, res); }
        @catch (NSException *e) { LPLog(@"[gold] lỗi: %@", e.reason); }
    });
    LPLog(@"[gold] processor đã gắn");
}

#pragma mark - fallback: nhân bản entitlement key (an toàn kiểu)

// VẤN ĐỀ: không biết chắc Locket đọc entitlement ID nào
// ("Gold"? "gold"? "locket_gold"? "premium"?).
//
// KHÔNG THỂ bịa RCEntitlementInfo — đó là class thật, nhét NSDictionary vào là
// crash "unrecognized selector" (đúng lỗi v1.4–v1.11).
//
// CÁCH ĐÚNG: lấy object RCEntitlementInfo THẬT (do SDK parse từ JSON đã vá) rồi
// NHÂN BẢN nó dưới nhiều key khác nhau. Value vẫn là object đúng class →
// app gọi .isActive / .identifier / .expirationDate đều chạy bình thường.
// Không crash được, và phủ hết mọi tên key khả dĩ.

static NSArray<NSString *> *LPCandidateEntitlementKeys(void) {
    return @[@"Gold", @"gold", @"Gold ", @"Locket Gold", @"LocketGold",
             @"locket_gold", @"locket_gold_annual", @"locket_gold_monthly",
             @"premium", @"Premium", @"pro", @"Pro", @"plus", @"Plus",
             @"locket_plus", @"unlimited", @"subscription", @"vip", @"VIP"];
}

// Nhân bản entry "gold-ish" (hoặc entry đầu tiên) dưới mọi key khả dĩ.
static NSDictionary *LPExpandEntitlements(NSDictionary *real) {
    if (![real isKindOfClass:[NSDictionary class]] || !real.count) return real;

    // Tìm entry đáng nhân bản: ưu tiên key chứa gold/premium/pro.
    id donor = nil;
    for (NSString *k in real.allKeys) {
        if (![k isKindOfClass:[NSString class]]) continue;
        NSString *lk = k.lowercaseString;
        if ([lk containsString:@"gold"] || [lk containsString:@"premium"] ||
            [lk containsString:@"pro"] || [lk containsString:@"plus"]) {
            donor = real[k];
            break;
        }
    }
    if (!donor) donor = real[real.allKeys.firstObject];
    if (!donor) return real;

    NSMutableDictionary *out = [real mutableCopy];
    for (NSString *k in LPCandidateEntitlementKeys()) {
        if (!out[k]) out[k] = donor;      // cùng object, đúng class
    }
    return out;
}

static NSDictionary *(*gOrigEntAll)(id, SEL);
static NSDictionary *LPEntAll(id self, SEL _cmd) {
    NSDictionary *real = gOrigEntAll ? gOrigEntAll(self, _cmd) : nil;
    if (![[LPConfig shared] flag:@"goldUnlock" fallback:YES]) return real;
    @try { return LPExpandEntitlements(real); }
    @catch (__unused NSException *e) { return real; }
}

static NSDictionary *(*gOrigEntActive)(id, SEL);
static NSDictionary *LPEntActive(id self, SEL _cmd) {
    NSDictionary *real = gOrigEntActive ? gOrigEntActive(self, _cmd) : nil;
    if (![[LPConfig shared] flag:@"goldUnlock" fallback:YES]) return real;
    @try {
        NSDictionary *out = LPExpandEntitlements(real);
        if ((!out || !out.count) && real) {
            LPLog(@"[gold] entitlements.active rỗng — JSON chưa được vá "
                  @"(có thể RevenueCat trả 304 từ cache)");
        }
        return out;
    } @catch (__unused NSException *e) { return real; }
}

// activeSubscriptions trả NSSet<NSString*> → thêm chuỗi vào là an toàn.
static id (*gOrigActiveSubs)(id, SEL);
static id LPActiveSubs(id self, SEL _cmd) {
    id real = gOrigActiveSubs ? gOrigActiveSubs(self, _cmd) : nil;
    if (![[LPConfig shared] flag:@"goldUnlock" fallback:YES]) return real;
    NSMutableSet *s = [real isKindOfClass:[NSSet class]] ? [real mutableCopy] : [NSMutableSet set];
    [s addObject:@"locket_gold_annual"];
    return s;
}

static void LPInstallGoldClassHooks(void) {
    Class ent = NSClassFromString(@"RCEntitlementInfos");
    if (ent) {
        LPHookMethodTyped(ent, @selector(all),    "@", (IMP)LPEntAll,    (IMP *)&gOrigEntAll);
        LPHookMethodTyped(ent, @selector(active), "@", (IMP)LPEntActive, (IMP *)&gOrigEntActive);
        LPLog(@"[gold] hook RCEntitlementInfos.all/.active (nhân bản key)");
    }
    Class ci = NSClassFromString(@"RCCustomerInfo");
    if (ci) {
        LPHookMethodTyped(ci, @selector(activeSubscriptions), "@",
                          (IMP)LPActiveSubs, (IMP *)&gOrigActiveSubs);
        LPLog(@"[gold] hook RCCustomerInfo.activeSubscriptions");
    }
}

void LPInstallGoldHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LPInstallGoldClassHooks();
        // RevenueCat nạp muộn → thử lại vài lần.
        for (int i = 1; i <= 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                static BOOL retried = NO;
                if (retried) return;
                if (!NSClassFromString(@"RCEntitlementInfos") &&
                    !NSClassFromString(@"RCCustomerInfo")) return;
                retried = YES;
                LPInstallGoldClassHooks();
                LPLog(@"[gold] hook muộn OK");
            });
        }
        LPLog(@"[gold] xong");
    });
}
