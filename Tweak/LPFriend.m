#import "LPCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

//
// LPFriend — chẩn đoán kết bạn.
//
// Sự thật (đã kiểm chứng trên binary 2.68 + Cloud Functions của project locket-4252a):
//   sendFriendRequest / acceptFriendRequest chạy trên Firebase Functions và server
//   kiểm tra X-Firebase-AppCheck. Bản IPA ký lại bằng chứng chỉ khác không tạo được
//   attestation hợp lệ cho team SWD4AZY4KG → server từ chối. Không client nào phá được.
//
// Việc CÓ THỂ làm ở client, và tweak này làm:
//   1. Bắt mọi request kết bạn + in nguyên HTTP status / body / mã lỗi để biết chính xác
//      server chặn ở đâu (401 = auth, 403 = App Check / permission, 400 = payload).
//   2. Nếu là 401 do token cũ (keychain bị đứt khi sideload) → ép refresh ID token
//      rồi replay 1 lần. Trường hợp này THẬT SỰ cứu được.
//   3. Nếu là 403 App Check → log rõ "không cứu được trên bản sideload".
//
// ĐÃ BỎ so với bản trước: hook -[GTMSessionFetcher startWithCompletionHandler:]
//   rồi KVC "request"/"response" — GTMSessionFetcher không có property đó,
//   mỗi lần gọi là ném NSException → app chết ngay khi mở.
//

static NSMutableArray<NSDictionary *> *gFriendLog;
static BOOL gFriendHooks = NO;
static BOOL gAuthRecovered = NO;

#pragma mark - nhận diện + log

static BOOL LPFriendURL(NSURL *url) {
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *path = url.path.lowercaseString ?: @"";
    BOOL hostOK = [host isEqualToString:@"api.locketcamera.com"] ||
                  [host hasSuffix:@".cloudfunctions.net"] ||
                  [host hasSuffix:@"cloudfunctions.net"];
    if (!hostOK) return NO;
    return [path containsString:@"sendfriendrequest"] || [path containsString:@"acceptfriendrequest"];
}

static NSString *LPTrunc(id obj, NSUInteger n) {
    NSString *s = nil;
    if ([obj isKindOfClass:[NSData class]]) {
        s = [[NSString alloc] initWithData:obj encoding:NSUTF8StringEncoding];
        if (!s) s = [(NSData *)obj base64EncodedStringWithOptions:0];
    } else if (obj) s = [obj description];
    if (!s) return @"";
    return s.length > n ? [[s substringToIndex:n] stringByAppendingString:@"…"] : s;
}

static void LPAddFriendLog(NSString *line) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gFriendLog = [NSMutableArray array]; });
    @synchronized (gFriendLog) {
        [gFriendLog addObject:@{@"t": [NSDate date], @"m": line ?: @""}];
        if (gFriendLog.count > 300) [gFriendLog removeObjectAtIndex:0];
    }
    LPLog(@"[friend] %@", line);
}

static NSString *LPFriendLogText(void) {
    NSMutableString *s = [NSMutableString string];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss";
    @synchronized (gFriendLog) {
        for (NSDictionary *e in gFriendLog) [s appendFormat:@"[%@] %@\n", [df stringFromDate:e[@"t"]], e[@"m"]];
    }
    return s.length ? s : @"(chưa có sự kiện kết bạn nào)";
}

#pragma mark - Firebase (gọi động, không link)

static id LPFirebaseApp(void) {
    Class FIRApp = NSClassFromString(@"FIRApp");
    return FIRApp ? [FIRApp performSelector:NSSelectorFromString(@"defaultApp")] : nil;
}

static void LPFetchIDToken(void (^done)(NSString *token, NSString *err)) {
    Class FIRAuth = NSClassFromString(@"FIRAuth");
    id app = LPFirebaseApp();
    if (!FIRAuth || !app) { done(nil, @"không có FIRAuth/FIRApp"); return; }
    id auth = ((id (*)(id, SEL, id))objc_msgSend)((id)FIRAuth, NSSelectorFromString(@"authWithApp:"), app);
    id user = ((id (*)(id, SEL))objc_msgSend)(auth, NSSelectorFromString(@"currentUser"));
    if (!user) { done(nil, @"chưa đăng nhập"); return; }
    SEL sel = NSSelectorFromString(@"getIDTokenForcingRefresh:completion:");
    if (![user respondsToSelector:sel]) { done(nil, @"thiếu getIDTokenForcingRefresh:completion:"); return; }
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(user, sel, YES, ^(NSString *token, NSError *error) {
        done(error ? nil : token, error ? error.localizedDescription : nil);
    });
}

static void LPFetchAppCheckToken(void (^done)(NSString *token, NSString *err)) {
    Class FIRAppCheck = NSClassFromString(@"FIRAppCheck");
    id app = LPFirebaseApp();
    if (!FIRAppCheck || !app) { done(nil, @"không có FIRAppCheck/FIRApp"); return; }
    id ac = ((id (*)(id, SEL, id))objc_msgSend)((id)FIRAppCheck, NSSelectorFromString(@"appCheckWithApp:"), app);
    SEL sel = NSSelectorFromString(@"tokenForcingRefresh:completion:");
    if (!ac || ![ac respondsToSelector:sel]) { done(nil, @"thiếu tokenForcingRefresh:completion:"); return; }
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(ac, sel, YES, ^(id token, NSError *error) {
        NSString *s = nil;
        if (token && [token respondsToSelector:NSSelectorFromString(@"token")])
            s = ((id (*)(id, SEL))objc_msgSend)(token, NSSelectorFromString(@"token"));
        done(s, error ? error.localizedDescription : (s ? nil : @"token rỗng"));
    });
}

#pragma mark - replay

static void LPReplay(NSURLRequest *original, NSString *idToken, NSString *acToken) {
    NSMutableURLRequest *req = [original mutableCopy];
    if (idToken) [req setValue:[@"Bearer " stringByAppendingString:idToken] forHTTPHeaderField:@"Authorization"];
    if (acToken) [req setValue:acToken forHTTPHeaderField:@"X-Firebase-AppCheck"];
    LPAddFriendLog([NSString stringWithFormat:@"[replay] %@ %@", req.HTTPMethod, req.URL.path]);
    // Dùng session riêng để replay KHÔNG bị hook của chính mình bắt lại (vòng lặp vô hạn).
    NSURLSession *s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[s dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        LPAddFriendLog([NSString stringWithFormat:@"[replay] -> HTTP %ld body=%@ err=%@",
                        (long)[(NSHTTPURLResponse *)resp statusCode], LPTrunc(data, 900),
                        err.localizedDescription ?: @"-"]);
        [s finishTasksAndInvalidate];
    }] resume];
}

#pragma mark - xử lý phản hồi

static void LPHandleFriendResponse(NSURLRequest *req, NSData *data, NSURLResponse *resp, NSError *err) {
    NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@ %@ -> HTTP %ld",
                             req.HTTPMethod, req.URL.path, (long)code];
    if (err) [line appendFormat:@" (err %@ %ld)", err.domain, (long)err.code];
    if (req.HTTPBody) [line appendFormat:@"\n   req: %@", LPTrunc(req.HTTPBody, 600)];
    if (data.length) [line appendFormat:@"\n   res: %@", LPTrunc(data, 900)];
    LPAddFriendLog(line);

    // 401 = token đăng nhập cũ/hỏng → refresh + replay có thể cứu.
    // 403 = App Check / permission → bản sideload không cứu được, chỉ log.
    if (code == 401 && !gAuthRecovered &&
        [[LPConfig shared] flag:@"autoRefreshOnAuthFail" fallback:YES]) {
        gAuthRecovered = YES;
        LPAddFriendLog(@"401 → ép làm mới ID token rồi replay 1 lần");
        LPFetchIDToken(^(NSString *idToken, NSString *idErr) {
            LPAddFriendLog(idToken ? [NSString stringWithFormat:@"ID token: ok (%lu ký tự)", (unsigned long)idToken.length]
                                   : [@"ID token: FAIL " stringByAppendingString:idErr ?: @""]);
            if (!idToken) return;
            LPFetchAppCheckToken(^(NSString *acToken, NSString *acErr) {
                LPAddFriendLog(acToken ? [NSString stringWithFormat:@"AppCheck: ok (%lu ký tự)", (unsigned long)acToken.length]
                                       : [@"AppCheck: FAIL " stringByAppendingString:acErr ?: @""]);
                LPReplay(req, idToken, acToken);
            });
        });
    } else if (code == 403) {
        LPAddFriendLog(@"403 → App Check/attestation của team gốc. Bản sideload không tạo được attestation hợp lệ.");
    }
}

#pragma mark - hook NSURLSession (chỉ request kết bạn)

static id LPDataTaskHook(id self, SEL _cmd, NSURLRequest *req, id completion) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    if (!LPFriendURL(req.URL)) return ((id (*)(id, SEL, NSURLRequest *, id))o)(self, _cmd, req, completion);
    void (^orig)(NSData *, NSURLResponse *, NSError *) = completion;
    id wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        @try { LPHandleFriendResponse(req, data, resp, err); } @catch (__unused NSException *e) {}
        if (orig) orig(data, resp, err);
    };
    return ((id (*)(id, SEL, NSURLRequest *, id))o)(self, _cmd, req, wrapped);
}

static id LPUploadTaskHook(id self, SEL _cmd, NSURLRequest *req, NSData *body, id completion) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    if (!LPFriendURL(req.URL)) return ((id (*)(id, SEL, NSURLRequest *, NSData *, id))o)(self, _cmd, req, body, completion);
    void (^orig)(NSData *, NSURLResponse *, NSError *) = completion;
    id wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        @try { LPHandleFriendResponse(req, data, resp, err); } @catch (__unused NSException *e) {}
        if (orig) orig(data, resp, err);
    };
    return ((id (*)(id, SEL, NSURLRequest *, NSData *, id))o)(self, _cmd, req, body, wrapped);
}

#pragma mark - probe

// Chẩn đoán KHÔNG hiện UI: ghi kết quả vào Documents/LocketPlus/friend.log
// để xem lại bằng file, không làm phiền người dùng.
void LPRunFriendProbe(UIViewController *host) {
    (void)host;
    NSMutableString *out = [NSMutableString string];
    [out appendString:LPFriendLogText()];
    [out appendString:@"\n===== probe =====\n"];
    [out appendFormat:@"FIRAuth: %@ | FIRAppCheck: %@\n",
        NSClassFromString(@"FIRAuth") ? @"có" : @"KHÔNG",
        NSClassFromString(@"FIRAppCheck") ? @"có" : @"KHÔNG"];
    LPFetchIDToken(^(NSString *idToken, NSString *idErr) {
        [out appendFormat:@"ID token: %@\n",
            idToken ? [NSString stringWithFormat:@"ok %lu ký tự", (unsigned long)idToken.length] : idErr];
        LPFetchAppCheckToken(^(NSString *acToken, NSString *acErr) {
            [out appendFormat:@"AppCheck: %@\n",
                acToken ? [NSString stringWithFormat:@"ok %lu ký tự", (unsigned long)acToken.length] : acErr];
            [out appendString:@"\n401 → refresh cứu được. 403 → App Check, không cứu được.\n"];
            [out writeToFile:[LPConfig path:@"friend.log"] atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
            LPLog(@"[friend] probe đã ghi friend.log");
        });
    });
}

#pragma mark - install

void LPInstallFriendTools(void) {
    if (gFriendHooks) return;
    gFriendHooks = YES;

    // NSURLSession là class cluster: method nằm trên NSURLSession nên hook ở đây
    // áp dụng cho mọi session (kể cả session của Firebase). Chỉ request khớp
    // LPFriendURL mới bị bọc, còn lại đi thẳng.
    Class s = NSClassFromString(@"NSURLSession");
    BOOL a = LPHookMethod(s, @selector(dataTaskWithRequest:completionHandler:), (IMP)LPDataTaskHook, NULL);
    BOOL b = LPHookMethod(s, @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)LPUploadTaskHook, NULL);
    LPLog(@"[friend] hook NSURLSession data=%d upload=%d", a, b);
    LPAddFriendLog(@"bộ chẩn đoán kết bạn đã bật");
}
