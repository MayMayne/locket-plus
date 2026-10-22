// ============================================================================
//  LPRemoteConfig.m — vá FIRRemoteConfigValue
//
//  ĐÂY LÀ CHỖ THẬT SỰ MỞ ĐƯỢC HẠN MỨC KẾT BẠN.
//
//  Locket đọc các key sau từ Firebase Remote Config rồi tự chặn ở client:
//    friend_limit_mode, max_friends_count, soft_friend_limit_threshold_count,
//    unlimited_max_friend_count, signup_max_friends_count
//  và hiện "You already have %d friends" / "You can only add up to %d friends".
//  Nếu bạn đang chạm TRẦN BẠN BÈ (không phải App Check), đây là gate duy nhất
//  cần mở — server vẫn nhận request vì request được gửi đi bình thường.
//
//  Cũng dùng để mở các gate Gold đọc qua Remote Config:
//    gold_camera_themes, camera_theme_upsell, longer_video, remove_ads...
//
//  AN TOÀN KIỂU — đây là lỗi làm bản cũ không chạy:
//    boolValue     → BOOL        (ký tự 'B' hoặc 'c')
//    numberValue   → NSNumber *  ('@')
//    integerValue  → long long   ('q')
//    stringValue   → NSString *  ('@')
//  Bản cũ khai báo LPRCInt trả long long nhưng gọi IMP của numberValue
//  (trả NSNumber*) với selector integerValue → đọc rác.
//  Bản này mỗi hàm gọi ĐÚNG IMP của chính nó qua LPOrigIMPFor.
//
//  Đọc tên key: KVC không đọc được ivar `_key` (KVC bỏ qua ivar có gạch dưới),
//  nên phải đọc thẳng từ object layout — nhưng CHỈ khi type encoding khớp.
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>
#import <string.h>

#pragma mark - đọc tên key của FIRRemoteConfigValue

// Trả về NSString của key, hoặc nil. An toàn: chỉ đọc khi ivar có kiểu đúng.
static NSString *LPRCKey(id obj) {
    if (!obj) return nil;
    @try {
        for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
            if (c == [NSObject class]) break;
            unsigned int n = 0;
            Ivar *ivs = class_copyIvarList(c, &n);
            if (!ivs) continue;
            NSString *found = nil;
            for (unsigned i = 0; i < n; i++) {
                const char *name = ivar_getName(ivs[i]);
                const char *type = ivar_getTypeEncoding(ivs[i]);
                if (!name || !type) continue;
                if (strcmp(name, "_key") != 0 &&
                    strcmp(name, "key") != 0 &&
                    strcmp(name, "_configKey") != 0) continue;

                ptrdiff_t off = ivar_getOffset(ivs[i]);
                void *base = (__bridge void *)obj;
                if (strcmp(type, "@\"NSString\"") == 0 || strcmp(type, "@") == 0) {
                    NSString *s = (__bridge NSString *)(*(void **)((char *)base + off));
                    if ([s isKindOfClass:[NSString class]]) found = s;
                } else if (strcmp(type, "*") == 0) {
                    const char *cs = *(const char **)((char *)base + off);
                    if (cs) found = [NSString stringWithUTF8String:cs];
                }
                break;
            }
            free(ivs);
            if (found) return found;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

#pragma mark - chính sách vá

// Key hạn mức bạn bè → trả số rất lớn (client không chặn nữa).
static BOOL LPIsFriendLimitKey(NSString *k) {
    NSString *l = k.lowercaseString;
    if (![l containsString:@"friend"]) return NO;
    return [l containsString:@"limit"] || [l containsString:@"max"] ||
           [l containsString:@"count"] || [l containsString:@"threshold"];
}

// friend_limit_mode là ENUM dạng chuỗi ("soft"/"hard"/"unlimited"), không phải
// số. Trả "999999" cho nó là sai kiểu → app parse fail. Phải trả "unlimited".
static BOOL LPIsFriendModeKey(NSString *k) {
    NSString *l = k.lowercaseString;
    return [l containsString:@"friend"] && [l containsString:@"mode"];
}

// Key bật tính năng Gold → trả YES.
// CẨN THẬN: đây là hook boolValue của TOÀN BỘ Remote Config, nên từ khoá phải
// đủ hẹp. "pro_" từng khớp cả "production" → sẽ lật cờ môi trường. Bỏ.
static BOOL LPIsGoldFlagKey(NSString *k) {
    NSString *l = k.lowercaseString;
    static NSArray *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[@"gold", @"premium", @"camera_theme", @"theme_gold",
                  @"badge", @"remove_ads", @"streak_recovery",
                  @"priority_support", @"longer_video", @"unlimited_friend"];
    });
    for (NSString *w in words) if ([l containsString:w]) return YES;
    return NO;
}

// Key giới hạn video → trả trần của ta.
static BOOL LPIsVideoDurationKey(NSString *k) {
    NSString *l = k.lowercaseString;
    if (![l containsString:@"video"]) return NO;
    return [l containsString:@"duration"] || [l containsString:@"second"] ||
           [l containsString:@"length"] || [l containsString:@"max_time"];
}

static BOOL LPIsVideoSizeKey(NSString *k) {
    NSString *l = k.lowercaseString;
    if (![l containsString:@"video"]) return NO;
    return [l containsString:@"size"] || [l containsString:@"byte"] ||
           [l containsString:@"mb"] || [l containsString:@"max_size"];
}

static BOOL LPIsVideoFlagKey(NSString *k) {
    NSString *l = k.lowercaseString;
    if (![l containsString:@"video"]) return NO;
    return [l containsString:@"enabled"] || [l containsString:@"allowed"] ||
           [l containsString:@"unlimited"] || [l containsString:@"long"];
}

#pragma mark - hooks

static BOOL (*gOrigBool)(id, SEL);
static BOOL LPBool(id self, SEL _cmd) {
    BOOL real = gOrigBool ? gOrigBool(self, _cmd) : NO;
    if (real) return YES;
    @try {
        NSString *k = LPRCKey(self);
        if (!k.length) return real;
        if (LPIsFriendLimitKey(k) && [[LPConfig shared] flag:@"friendLimitUnlock" fallback:YES]) return YES;
        if (LPIsGoldFlagKey(k) && [[LPConfig shared] flag:@"goldUnlock" fallback:YES]) return YES;
        if (LPIsVideoFlagKey(k)) return YES;
    } @catch (__unused NSException *e) {}
    return real;
}

static NSNumber *(*gOrigNumber)(id, SEL);
static NSNumber *LPNumber(id self, SEL _cmd) {
    NSNumber *real = gOrigNumber ? gOrigNumber(self, _cmd) : nil;
    @try {
        NSString *k = LPRCKey(self);
        if (!k.length) return real;
        if (LPIsFriendLimitKey(k) && [[LPConfig shared] flag:@"friendLimitUnlock" fallback:YES]) {
            return @(999999);
        }
        if (LPIsVideoDurationKey(k)) return @(LPVideoSeconds());
        if (LPIsVideoSizeKey(k)) return @(LPVideoBytes());
    } @catch (__unused NSException *e) {}
    return real;
}

static long long (*gOrigInt)(id, SEL);
static long long LPInt(id self, SEL _cmd) {
    long long real = gOrigInt ? gOrigInt(self, _cmd) : 0;
    @try {
        NSString *k = LPRCKey(self);
        if (!k.length) return real;
        if (LPIsFriendLimitKey(k) && [[LPConfig shared] flag:@"friendLimitUnlock" fallback:YES]) {
            return 999999;
        }
        if (LPIsVideoDurationKey(k)) return (long long)LPVideoSeconds();
        if (LPIsVideoSizeKey(k)) return (long long)LPVideoBytes();
    } @catch (__unused NSException *e) {}
    return real;
}

static NSString *(*gOrigString)(id, SEL);
static NSString *LPString(id self, SEL _cmd) {
    NSString *real = gOrigString ? gOrigString(self, _cmd) : nil;
    @try {
        NSString *k = LPRCKey(self);
        if (!k.length) return real;
        if (LPIsFriendModeKey(k) && [[LPConfig shared] flag:@"friendLimitUnlock" fallback:YES]) {
            return @"unlimited";
        }
        if (LPIsFriendLimitKey(k) && [[LPConfig shared] flag:@"friendLimitUnlock" fallback:YES]) {
            return @"999999";
        }
        if (LPIsVideoDurationKey(k)) {
            return [NSString stringWithFormat:@"%.0f", LPVideoSeconds()];
        }
        if (LPIsVideoSizeKey(k)) {
            return [NSString stringWithFormat:@"%.0f", LPVideoBytes()];
        }
    } @catch (__unused NSException *e) {}
    return real;
}

static void LPInstallRCOn(Class rc) {
    if (!rc) return;
    // Kiểm tra kiểu trả trước khi hook — sai kiểu là crash.
    LPHookMethodTyped(rc, @selector(boolValue),    "B", (IMP)LPBool,   (IMP *)&gOrigBool);
    LPHookMethodTyped(rc, @selector(numberValue),  "@", (IMP)LPNumber, (IMP *)&gOrigNumber);
    LPHookMethodTyped(rc, @selector(integerValue), "q", (IMP)LPInt,    (IMP *)&gOrigInt);
    LPHookMethodTyped(rc, @selector(stringValue),  "@", (IMP)LPString, (IMP *)&gOrigString);
    LPLog(@"[rc] hook %@", NSStringFromClass(rc));
}

void LPInstallRemoteConfigHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class rc = NSClassFromString(@"FIRRemoteConfigValue");
        if (rc) { LPInstallRCOn(rc); return; }

        // Firebase nạp muộn → thử lại tối đa 20s.
        for (int i = 1; i <= 40; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                static BOOL done = NO;
                if (done) return;
                Class c = NSClassFromString(@"FIRRemoteConfigValue");
                if (!c) return;
                done = YES;
                LPInstallRCOn(c);
            });
        }
        LPLog(@"[rc] chưa thấy FIRRemoteConfigValue — sẽ thử lại");
    });
}
