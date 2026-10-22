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

#pragma mark - xoá cache CustomerInfo (chỉ 1 lần)

// RevenueCat lưu CustomerInfo vào NSUserDefaults và CHỈ gọi mạng khi cache cũ.
// Nếu lần đầu cài bản mod mà cache đang nói "không có Gold", processor JSON
// không có cơ hội chạy → Gold không mở dù code đúng.
//
// Xoá ĐÚNG các key cache, TUYỆT ĐỐI không xoá key appUserID: xoá nó thì
// RevenueCat sinh anonymous ID mới và mất luôn giao dịch thật đã mua.
void LPInvalidateRevenueCatCacheOnce(void) {
    if (![[LPConfig shared] flag:@"goldUnlock" fallback:YES]) return;

    NSString *marker = LPPath(@"rc.cache.cleared");
    if ([[NSFileManager defaultManager] fileExistsAtPath:marker]) return;

    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSDictionary *all = [ud dictionaryRepresentation];
        NSMutableArray<NSString *> *victims = [NSMutableArray array];

        for (NSString *k in all.allKeys) {
            if (![k isKindOfClass:[NSString class]]) continue;
            NSString *l = k.lowercaseString;
            if (![l containsString:@"revenuecat"]) continue;
            // Bảo vệ danh tính người dùng — mất cái này là mất quyền mua thật.
            if ([l containsString:@"appuserid"] || [l containsString:@"app_user_id"]) continue;
            if ([l containsString:@"purchaserinfo"] || [l containsString:@"customerinfo"]) {
                [victims addObject:k];
            }
        }
        for (NSString *k in victims) [ud removeObjectForKey:k];
        [ud synchronize];

        [@"ok" writeToFile:marker atomically:YES
                 encoding:NSUTF8StringEncoding error:nil];
        LPLog(@"[gold] xoá %lu key cache CustomerInfo (giữ appUserID)",
              (unsigned long)victims.count);
    } @catch (NSException *e) {
        LPLog(@"[gold] xoá cache lỗi: %@", e.reason);
    }
}

#pragma mark - KHÔNG hook class RevenueCat

// AutoRcSideload (bản chạy được) KHÔNG hook RCEntitlementInfos / RCCustomerInfo.
// Nó chỉ rewrite JSON response. Tôi từng thêm 2 hook "cho chắc" — đó là tự bịa,
// và mỗi hook thêm là một đường dẫn tới crash.
//
// Lý do KHÔNG hook:
//   • RCEntitlementInfos.all/.active trả NSDictionary<NSString*, RCEntitlementInfo>
//     — value là OBJECT thật. Nhân bản object dưới nhiều key (cách tôi làm) có
//     thể làm RevenueCat so sánh `identifier != key` rồi hành xử lạ.
//   • RCCustomerInfo.activeSubscriptions trả NSSet<NSString*> — thêm chuỗi vào
//     thì "an toàn" về kiểu, nhưng SDK có thể dùng nó để tra `subscriptions`
//     dictionary và không thấy → trả nil ở chỗ khác.
//
// Nếu JSON rewrite không đủ (RevenueCat dùng cache), cách đúng là xoá cache —
// LPInvalidateRevenueCatCacheOnce() đã làm việc đó.
