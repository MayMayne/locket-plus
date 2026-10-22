// ============================================================================
//  LPFriend.m — chẩn đoán kết bạn + hồi phục token
//
//  BÁM SÁT MHProfileSupport.dylib (bản V28 của Minh Hiếu, đã dịch ngược 106 hàm):
//    • Bọc completion của NSURLSession CHỈ với request kết bạn
//    • Ghi HTTP status + mã lỗi server trả về
//    • 401 → ép refresh FIRAuth ID token + FIRAppCheck token rồi replay 1 lần
//    • 403 → log rõ: App Check / attestation, bản sideload không cứu được
//    • Báo cáo ghi ra Documents/LocketPlus/friend.log, KHÔNG hiện UI
//
//  Sự thật kỹ thuật (đã kiểm chứng nhiều lần):
//    sendFriendRequest / acceptFriendRequest là Cloud Functions (project
//    locket-4252a). Server kiểm X-Firebase-AppCheck. Bản ký lại bằng cert khác
//    KHÔNG tạo được attestation hợp lệ cho team SWD4AZY4KG. Refresh token
//    không tạo ra attestation. Vì vậy:
//      401 (token cũ/hỏng do keychain đứt)  → CỨU ĐƯỢC bằng refresh + replay.
//      403 (App Check từ chối)              → KHÔNG cứu được ở client.
//    Đường còn lại: cài bằng TrollStore/jailbreak giữ chữ ký gốc, hoặc nhờ
//    người dùng bản App Store gốc bấm accept link mời.
// ============================================================================

#import "LPCommon.h"
#import <objc/message.h>

static BOOL gFriendHooks = NO;
static BOOL gAuthRecovered = NO;
static NSMutableArray<NSString *> *gFriendLines;
static NSLock *gFriendLock;

#pragma mark - log

static void LPFriendLogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gFriendLines = [NSMutableArray array];
        gFriendLock = [NSLock new];
    });
}

static void LPFriendAdd(NSString *line) {
    if (!line.length) return;
    LPFriendLogInit();
    [gFriendLock lock];
    [gFriendLines addObject:line];
    if (gFriendLines.count > 400) [gFriendLines removeObjectAtIndex:0];
    [gFriendLock unlock];
    LPLog(@"[friend] %@", line);
}

static NSString *LPFriendText(void) {
    LPFriendLogInit();
    [gFriendLock lock];
    NSString *s = [gFriendLines componentsJoinedByString:@"\n"];
    [gFriendLock unlock];
    return s.length ? s : @"(chưa có sự kiện kết bạn)";
}

static NSString *LPTrunc(id obj, NSUInteger n) {
    NSString *s = nil;
    if ([obj isKindOfClass:[NSData class]]) {
        s = [[NSString alloc] initWithData:obj encoding:NSUTF8StringEncoding];
        if (!s) s = [(NSData *)obj base64EncodedStringWithOptions:0];
    } else if (obj) {
        s = [obj description];
    }
    if (!s) return @"";
    return s.length > n ? [[s substringToIndex:n] stringByAppendingString:@"…"] : s;
}

#pragma mark - nhận diện

static BOOL LPFriendURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    BOOL hostOK = [host isEqualToString:@"api.locketcamera.com"] ||
                  [host hasSuffix:@"cloudfunctions.net"] ||
                  [host hasSuffix:@".run.app"];
    if (!hostOK) return NO;
    return [path containsString:@"sendfriendrequest"] ||
           [path containsString:@"acceptfriendrequest"] ||
           [path containsString:@"removefriend"] ||
           [path containsString:@"friendrequest"];
}

#pragma mark - Firebase (gọi động)

static id LPFIRApp(void) {
    Class FIRApp = NSClassFromString(@"FIRApp");
    if (!FIRApp) return nil;
    SEL s = NSSelectorFromString(@"defaultApp");
    if (![FIRApp respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)FIRApp, s);
}

static void LPFetchIDToken(void (^done)(NSString *, NSString *)) {
    if (!done) return;
    Class FIRAuth = NSClassFromString(@"FIRAuth");
    id app = LPFIRApp();
    if (!FIRAuth || !app) { done(nil, @"không có FIRAuth/FIRApp"); return; }

    SEL authSel = NSSelectorFromString(@"authWithApp:");
    if (![FIRAuth respondsToSelector:authSel]) { done(nil, @"thiếu authWithApp:"); return; }
    id auth = ((id (*)(id, SEL, id))objc_msgSend)((id)FIRAuth, authSel, app);
    if (!auth) { done(nil, @"auth nil"); return; }

    id user = ((id (*)(id, SEL))objc_msgSend)(auth, NSSelectorFromString(@"currentUser"));
    if (!user) { done(nil, @"chưa đăng nhập"); return; }

    SEL sel = NSSelectorFromString(@"getIDTokenForcingRefresh:completion:");
    if (![user respondsToSelector:sel]) { done(nil, @"thiếu getIDTokenForcingRefresh:"); return; }

    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(user, sel, YES,
        ^(NSString *token, NSError *error) {
            done(error ? nil : token, error ? error.localizedDescription : nil);
        });
}

static void LPFetchAppCheckToken(void (^done)(NSString *, NSString *)) {
    if (!done) return;
    Class FIRAppCheck = NSClassFromString(@"FIRAppCheck");
    id app = LPFIRApp();
    if (!FIRAppCheck || !app) { done(nil, @"không có FIRAppCheck/FIRApp"); return; }

    SEL acSel = NSSelectorFromString(@"appCheckWithApp:");
    if (![FIRAppCheck respondsToSelector:acSel]) { done(nil, @"thiếu appCheckWithApp:"); return; }
    id ac = ((id (*)(id, SEL, id))objc_msgSend)((id)FIRAppCheck, acSel, app);
    if (!ac) { done(nil, @"appCheck nil"); return; }

    SEL sel = NSSelectorFromString(@"tokenForcingRefresh:completion:");
    if (![ac respondsToSelector:sel]) { done(nil, @"thiếu tokenForcingRefresh:"); return; }

    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(ac, sel, YES,
        ^(id token, NSError *error) {
            NSString *s = nil;
            if (token && [token respondsToSelector:NSSelectorFromString(@"token")]) {
                s = ((id (*)(id, SEL))objc_msgSend)(token, NSSelectorFromString(@"token"));
            }
            done(s, error ? error.localizedDescription : (s ? nil : @"token rỗng"));
        });
}

#pragma mark - replay

static void LPReplay(NSURLRequest *original, NSString *idToken, NSString *acToken) {
    NSMutableURLRequest *req = [original mutableCopy];
    if (idToken) [req setValue:[@"Bearer " stringByAppendingString:idToken]
            forHTTPHeaderField:@"Authorization"];
    if (acToken) [req setValue:acToken forHTTPHeaderField:@"X-Firebase-AppCheck"];

    LPFriendAdd([NSString stringWithFormat:@"[replay] %@ %@",
                 req.HTTPMethod, req.URL.path]);

    // Session riêng, ephemeral: replay KHÔNG bị hook của chính mình bắt lại
    // (nếu bắt lại → vòng lặp vô hạn).
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *s = [NSURLSession sessionWithConfiguration:cfg];
    [[s dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        LPFriendAdd([NSString stringWithFormat:@"[replay] → HTTP %ld body=%@ err=%@",
                     (long)code, LPTrunc(data, 800), err.localizedDescription ?: @"-"]);
        if (code == 403) {
            LPFriendAdd(@"[replay] 403 vẫn còn → App Check/attestation. Hết đường ở client.");
        }
        [s finishTasksAndInvalidate];
    }] resume];
}

#pragma mark - xử lý response

static void LPHandleFriendResponse(NSURLRequest *req, NSData *data,
                                   NSURLResponse *resp, NSError *err) {
    NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@ %@ → HTTP %ld",
                             req.HTTPMethod ?: @"?", req.URL.path ?: @"?", (long)code];
    if (err) [line appendFormat:@" (err %@ %ld)", err.domain, (long)err.code];
    if (data.length) [line appendFormat:@"\n   res: %@", LPTrunc(data, 800)];
    LPFriendAdd(line);

    // 401 = token cũ/hỏng → refresh + replay CỨU ĐƯỢC.
    if (code == 401 && !gAuthRecovered &&
        [[LPConfig shared] flag:@"autoRefreshOnAuthFail" fallback:YES]) {
        gAuthRecovered = YES;
        LPFriendAdd(@"401 → ép refresh ID token + App Check rồi replay 1 lần");
        LPFetchIDToken(^(NSString *idToken, NSString *idErr) {
            LPFriendAdd(idToken
                ? [NSString stringWithFormat:@"ID token OK (%lu ký tự)", (unsigned long)idToken.length]
                : [@"ID token FAIL: " stringByAppendingString:idErr ?: @""]);
            if (!idToken) return;
            LPFetchAppCheckToken(^(NSString *acToken, NSString *acErr) {
                LPFriendAdd(acToken
                    ? [NSString stringWithFormat:@"AppCheck OK (%lu ký tự)", (unsigned long)acToken.length]
                    : [@"AppCheck FAIL: " stringByAppendingString:acErr ?: @""]);
                LPReplay(req, idToken, acToken);
            });
        });
    } else if (code == 403) {
        LPFriendAdd(@"403 → App Check/attestation của team gốc. Bản sideload không tạo được.");
    } else if (code == 200 || code == 201) {
        LPFriendAdd(@"200 → kết bạn THÀNH CÔNG");
    }
}

#pragma mark - GTMSessionFetcher (Firebase dùng cái này, không dùng completion block)

// Firebase/GTMSessionFetcher gọi mạng qua DELEGATE, không qua completionHandler
// → hook NSURLSession completion KHÔNG bắt được request kết bạn.
// MHProfileSupport xử lý đúng chỗ này: nghe 2 notification của GTMSessionFetcher.
// Đây chỉ là observer, không swizzle gì → không thể crash app.
static void LPObserveFetcherNotifications(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    NSArray *names = @[@"com.google.GTMSessionFetcher.stopped",
                       @"com.google.GTMSessionFetcher.completionInvoked"];
    for (NSString *n in names) {
        [[NSNotificationCenter defaultCenter]
            addObserverForName:n object:nil queue:nil
                   usingBlock:^(NSNotification *note) {
            @autoreleasepool {
                @try {
                    id fetcher = note.object;
                    if (!fetcher) return;

                    id request = [fetcher valueForKey:@"request"];
                    if (![request isKindOfClass:[NSURLRequest class]]) return;
                    if (!LPFriendURL(((NSURLRequest *)request).URL)) return;

                    id response = [fetcher valueForKey:@"response"];
                    id data = [fetcher valueForKey:@"downloadedData"];
                    id error = [fetcher valueForKey:@"error"];

                    LPHandleFriendResponse(request,
                                           [data isKindOfClass:[NSData class]] ? data : nil,
                                           [response isKindOfClass:[NSURLResponse class]] ? response : nil,
                                           [error isKindOfClass:[NSError class]] ? error : nil);
                } @catch (NSException *e) {
                    LPLog(@"[friend] fetcher observer: %@", e.reason);
                }
            }
        }];
    }
    LPLog(@"[friend] đã nghe GTMSessionFetcher notifications");
}

#pragma mark - processor

void LPInstallFriendNetProcessor(void) {
    LPAddNetProcessor(^(NSURLRequest *req, LPNetResult *res) {
        @try {
            if (!LPFriendURL(req.URL)) return;
            LPHandleFriendResponse(req, res.data, res.response, nil);
        } @catch (NSException *e) { LPLog(@"[friend] lỗi: %@", e.reason); }
    });
    LPFriendAdd(@"bộ chẩn đoán kết bạn đã bật");
}

#pragma mark - probe

void LPRunFriendProbe(void) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"Locket+ friend probe — %@\n\n", [NSDate date]];
    [out appendString:LPFriendText()];
    [out appendString:@"\n\n===== môi trường =====\n"];
    [out appendFormat:@"FIRAuth: %@\n", NSClassFromString(@"FIRAuth") ? @"có" : @"KHÔNG"];
    [out appendFormat:@"FIRAppCheck: %@\n", NSClassFromString(@"FIRAppCheck") ? @"có" : @"KHÔNG"];
    [out appendFormat:@"FIRApp: %@\n", LPFIRApp() ? @"có" : @"KHÔNG"];
    [out appendFormat:@"RCCustomerInfo: %@\n", NSClassFromString(@"RCCustomerInfo") ? @"có" : @"KHÔNG"];

    LPFetchIDToken(^(NSString *idToken, NSString *idErr) {
        [out appendFormat:@"ID token: %@\n", idToken
            ? [NSString stringWithFormat:@"OK %lu ký tự", (unsigned long)idToken.length]
            : idErr];
        LPFetchAppCheckToken(^(NSString *acToken, NSString *acErr) {
            [out appendFormat:@"AppCheck: %@\n", acToken
                ? [NSString stringWithFormat:@"OK %lu ký tự", (unsigned long)acToken.length]
                : acErr];
            [out appendString:@"\n401 → refresh cứu được. 403 → App Check, không cứu được.\n"];
            [out writeToFile:LPPath(@"friend.log") atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
            LPLog(@"[friend] probe → friend.log");
        });
    });
}

#pragma mark - install

void LPInstallFriendTools(void) {
    if (gFriendHooks) return;
    gFriendHooks = YES;
    // Tầng mạng đã hook chung ở LPInstallNetHooks; ở đây gắn thêm:
    //  • processor cho NSURLSession completion (RevenueCat/Firebase REST)
    //  • observer cho GTMSessionFetcher (Firebase dùng đường này)
    LPInstallFriendNetProcessor();
    LPObserveFetcherNotifications();
}
