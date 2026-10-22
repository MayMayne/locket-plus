// ============================================================================
//  LPGold.m — mở khoá Gold phía client
//
//  BÁM SÁT AutoRcSideload.dylib. Bằng chứng đọc được từ binary:
//    • chỉ hook ĐÚNG 1 class (NSURLSession) với 2 selector:
//        dataTaskWithRequest:completionHandler:
//        dataTaskWithURL:completionHandler:
//      block signature: v32@?0@"NSData"8@"NSURLResponse"16@"NSError"24
//    • có hằng chuỗi "com.bypass.entitlement"
//    • phần còn lại mã hoá AES (BBAES) nên không đọc được key JSON trực tiếp.
//
//  => Cơ chế: REWRITE body JSON của RevenueCat trước khi SDK parse. SDK tự
//     dựng RCEntitlementInfo / RCSubscriptionInfo THẬT từ JSON, nên KHÔNG có
//     lỗi "unrecognized selector" như bản hook class (v1.4 → v1.11).
//
//  VÌ SAO KHÔNG HOOK CLASS (bài học đắt):
//    -[RCCustomerInfo entitlements] trả RCEntitlementInfos (một CLASS), không
//    phải NSDictionary. Trả NSDictionary → app gọi .active/.all lên nó → chết
//    ngay khi mở app. Cả hai in ra giống dictionary khi NSLog nên rất khó thấy.
//
//  GIỚI HẠN THẬT: server Locket vẫn coi tài khoản là free. Badge trên profile
//  người khác không hiện, hạn mức kết bạn phía server không đổi. Đây là client.
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>

// Entitlement identifier của Locket không đọc được từ binary (mã hoá).
// Nhét NHIỀU key cùng trỏ về một subscription hợp lệ: gate nào của app kiểm
// key nào cũng thấy. Value là dict JSON thật nên SDK tự tạo object đúng class.
static NSArray<NSString *> *LPGoldEntitlementKeys(void) {
    return @[@"Gold", @"gold", @"premium", @"Premium", @"pro", @"Pro",
             @"locket_gold", @"locketGold", @"vip", @"VIP", @"plus", @"Plus"];
}

static NSArray<NSString *> *LPGoldProductIDs(void) {
    return @[@"locket_gold_monthly", @"locket_gold_annual", @"locket_gold_yearly",
             @"com.locket.Locket.gold.monthly", @"com.locket.Locket.gold.annual",
             @"com.locket.Locket.gold.yearly", @"locket_gold", @"gold_monthly"];
}

#pragma mark - thời gian ISO8601

// Dùng NSISO8601DateFormatter thay NSDateFormatter: nó KHÔNG đọc locale từ
// NSUserDefaults (NSDateFormatter không set locale sẽ đọc), nên gọi được từ
// trong hook mạng mà không có nguy cơ đệ quy vào NSUserDefaults.
static NSString *LPIso(NSDate *d) {
    static NSISO8601DateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSISO8601DateFormatter new];
        df.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    });
    return [df stringFromDate:d ?: [NSDate date]];
}

static NSString *LPNow(void)  { return LPIso([NSDate date]); }
static NSString *LPFuture(void) {
    // 10 năm — đủ để app không tự hết hạn trong lúc dùng.
    return LPIso([NSDate dateWithTimeIntervalSinceNow:10.0 * 365 * 24 * 3600]);
}

#pragma mark - nhận diện response RevenueCat

static BOOL LPIsRevenueCat(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"api.revenuecat.com"]) return YES;
    if ([host hasSuffix:@".revenuecat.com"]) return YES;
    return NO;
}

// Chỉ sửa 2 endpoint này.
//   /v1/subscribers/<id>  → body có "subscriber"
//   /v1/receipts          → response cũng có "subscriber"
// KHÔNG sửa /v1/offerings hay /v1/products: offerings phải giữ nguyên để app
// hiển thị đúng giá, products không chứa entitlement.
static BOOL LPIsSubscriberPath(NSString *path) {
    NSString *p = path.lowercaseString ?: @"";
    if ([p containsString:@"/v1/subscribers/"]) return YES;
    if ([p containsString:@"/v1/receipts"]) return YES;
    return NO;
}

#pragma mark - dựng JSON

static NSDictionary *LPFakeEntitlement(NSString *productID) {
    return @{
        @"expires_date"      : LPFuture(),
        @"product_identifier": productID,
        @"purchase_date"     : LPNow()
    };
}

static NSDictionary *LPFakeSubscription(void) {
    return @{
        @"billing_issues_detected_at" : [NSNull null],
        @"expires_date"               : LPFuture(),
        @"is_sandbox"                 : @NO,
        @"original_purchase_date"     : LPNow(),
        @"period_type"                : @"normal",
        @"purchase_date"              : LPNow(),
        @"store"                      : @"app_store",
        @"unsubscribe_detected_at"    : [NSNull null],
        @"ownership_type"             : @"PURCHASED"
    };
}

// Vá một object "subscriber".
static NSDictionary *LPPatchSubscriber(NSDictionary *sub) {
    if (![sub isKindOfClass:[NSDictionary class]]) return sub;
    NSMutableDictionary *m = [sub mutableCopy];

    NSString *productID = LPGoldProductIDs().firstObject;

    // --- subscriptions ---
    NSMutableDictionary *subs = [NSMutableDictionary dictionary];
    id exSubs = m[@"subscriptions"];
    if ([exSubs isKindOfClass:[NSDictionary class]]) [subs addEntriesFromDictionary:exSubs];
    if (!subs.count) {
        for (NSString *pid in LPGoldProductIDs()) subs[pid] = LPFakeSubscription();
    }
    m[@"subscriptions"] = subs;

    // --- entitlements ---
    NSMutableDictionary *ents = [NSMutableDictionary dictionary];
    id existing = m[@"entitlements"];
    if ([existing isKindOfClass:[NSDictionary class]]) [ents addEntriesFromDictionary:existing];

    // Nếu đã có entitlement thật (user mua thật) thì GIỮ NGUYÊN, không ghi đè.
    BOOL hasReal = NO;
    for (NSString *k in ents.allKeys) {
        id v = ents[k];
        if (![v isKindOfClass:[NSDictionary class]]) continue;
        id exp = v[@"expires_date"];
        if (exp && exp != [NSNull null]) { hasReal = YES; break; }
    }
    if (!hasReal) {
        for (NSString *k in LPGoldEntitlementKeys()) {
            if (!ents[k]) ents[k] = LPFakeEntitlement(productID);
        }
    }
    m[@"entitlements"] = ents;

    // --- các trường phụ SDK đọc ---
    if (!m[@"original_app_user_id"]) m[@"original_app_user_id"] = @"$RCAnonymousID:locketplus";
    if (!m[@"first_seen"]) m[@"first_seen"] = LPNow();
    if (!m[@"last_seen"])  m[@"last_seen"]  = LPNow();
    if (!m[@"management_url"]) m[@"management_url"] = [NSNull null];
    if (!m[@"schema_version"]) m[@"schema_version"] = @12;

    return m;
}

// Đệ quy tìm key "subscriber" ở bất kỳ độ sâu nào.
static id LPPatchJSON(id obj, int depth) {
    if (!obj || depth > 12) return obj;

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
    if (![[LPConfig shared] flag:@"goldEnabled" fallback:YES]) return;
    if (!res || !res.data.length) return;
    if (!LPIsRevenueCat(req.URL)) return;
    if (!LPIsSubscriberPath(req.URL.path)) return;

    NSInteger code = [(NSHTTPURLResponse *)res.response statusCode];
    if (code != 200 && code != 201) return;

    @try {
        id json = [NSJSONSerialization JSONObjectWithData:res.data options:0 error:NULL];
        if (!json) return;

        id patched = LPPatchJSON(json, 0);
        if (!patched) return;

        NSData *out = [NSJSONSerialization dataWithJSONObject:patched options:0 error:NULL];
        if (!out.length) return;

        res.data = out;
        LPLog(@"[gold] vá RevenueCat %@ (%lu → %lu byte)",
              req.URL.path.lastPathComponent,
              (unsigned long)res.data.length, (unsigned long)out.length);
    } @catch (NSException *e) {
        LPLog(@"[gold] lỗi vá JSON: %@", e.reason);
    }
}

#pragma mark - xoá cache CustomerInfo một lần

// RevenueCat lưu CustomerInfo vào NSUserDefaults (key chứa "revenuecat" +
// "purchaserinfo"/"customerinfo") và vào file trong Application Support.
// Nếu cache cũ nói "không có Gold", SDK KHÔNG gọi mạng → processor không có
// cơ hội chạy → app vẫn free dù hook đúng.
//
// Chỉ xoá MỘT LẦN (đánh dấu bằng file), và GIỮ appUserID để không mất danh
// tính (mất appUserID là RevenueCat coi như user mới → mất giao dịch thật).
static void LPClearRevenueCatCacheOnce(void) {
    NSString *mark = LPPath(@"rc_cache_cleared_v5");
    if ([[NSFileManager defaultManager] fileExistsAtPath:mark]) return;

    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSDictionary *all = [ud dictionaryRepresentation];
        int removed = 0;
        for (NSString *k in all.allKeys) {
            if (![k isKindOfClass:[NSString class]]) continue;
            NSString *lk = k.lowercaseString;
            if (![lk containsString:@"revenuecat"]) continue;
            // GIỮ appUserID / anonymous id.
            if ([lk containsString:@"appuserid"] || [lk containsString:@"app_user_id"]) continue;
            if ([lk containsString:@"purchaserinfo"] || [lk containsString:@"customerinfo"]) {
                [ud removeObjectForKey:k];
                removed++;
            }
        }
        [ud synchronize];

        // File cache trong Application Support / Caches.
        NSArray *dirs = @[
            NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: @"",
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @""
        ];
        for (NSString *base in dirs) {
            if (!base.length) continue;
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:base];
            NSString *rel;
            while ((rel = [en nextObject])) {
                NSString *lr = rel.lowercaseString;
                if (![lr containsString:@"revenuecat"]) continue;
                if ([lr containsString:@"appuserid"]) continue;
                if ([lr containsString:@"purchaserinfo"] || [lr containsString:@"customerinfo"]) {
                    [fm removeItemAtPath:[base stringByAppendingPathComponent:rel] error:nil];
                    removed++;
                }
            }
        }

        [@"1" writeToFile:mark atomically:YES encoding:NSUTF8StringEncoding error:nil];
        LPLog(@"[gold] xoá %d mục cache RevenueCat (giữ appUserID)", removed);
    } @catch (NSException *e) {
        LPLog(@"[gold] xoá cache lỗi: %@", e.reason);
    }
}

#pragma mark - install

void LPInstallGold(void) {
    if (![[LPConfig shared] flag:@"goldEnabled" fallback:YES]) {
        LPLog(@"[gold] tắt theo config");
        return;
    }
    LPClearRevenueCatCacheOnce();
    LPAddNetProcessor(^(NSURLRequest *req, LPNetResult *res) {
        LPGoldProcessor(req, res);
    });
    LPLog(@"[gold] đã cắm processor RevenueCat");
}
