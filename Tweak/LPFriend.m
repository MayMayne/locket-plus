#import "LPCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSMutableArray<NSDictionary *> *gFriendLog;
static BOOL gFriendHooks = NO;

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

static void LPReplay(NSURLRequest *original, NSInteger attempt, NSString *idToken, NSString *acToken) {
    NSMutableURLRequest *req = [original mutableCopy];
    if (idToken) [req setValue:[@"Bearer " stringByAppendingString:idToken] forHTTPHeaderField:@"Authorization"];
    if (acToken) [req setValue:acToken forHTTPHeaderField:@"X-Firebase-AppCheck"];
    LPAddFriendLog([NSString stringWithFormat:@"[replay %ld] %@ %@", (long)attempt, req.HTTPMethod, req.URL.path]);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            LPAddFriendLog([NSString stringWithFormat:@"[replay %ld] -> HTTP %ld body=%@ err=%@",
                            (long)[(NSHTTPURLResponse *)resp statusCode], LPTrunc(data, 700),
                            err.localizedDescription ?: @"-"]);
        }] resume];
}

#pragma mark - xử lý phản hồi

static void LPHandleFriendResponse(NSURLRequest *req, NSData *data, NSURLResponse *resp, NSError *err) {
    NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@ %@ -> HTTP %ld",
                             req.HTTPMethod, req.URL.path, (long)code];
    if (err) [line appendFormat:@" (err %@ %ld)", err.domain, (long)err.code];
    if (req.HTTPBody) [line appendFormat:@"\n   req: %@", LPTrunc(req.HTTPBody, 900)];
    if (data.length) [line appendFormat:@"\n   res: %@", LPTrunc(data, 900)];
    LPAddFriendLog(line);

    if (!(code == 401 || code == 403)) return;
    if (![[LPConfig shared] flag:@"autoRefreshOnAuthFail" fallback:YES]) return;

    LPAddFriendLog(@"bị 401/403 → làm mới ID token + App Check token và replay 1 lần");
    LPFetchIDToken(^(NSString *idToken, NSString *idErr) {
        LPAddFriendLog([NSString stringWithFormat:@"ID token: %@",
                        idToken ? [NSString stringWithFormat:@"ok (%lu ký tự)", (unsigned long)idToken.length]
                                : [@"FAIL " stringByAppendingString:idErr ?: @""]]);
        LPFetchAppCheckToken(^(NSString *acToken, NSString *acErr) {
            LPAddFriendLog([NSString stringWithFormat:@"AppCheck token: %@",
                            acToken ? [NSString stringWithFormat:@"ok (%lu ký tự)", (unsigned long)acToken.length]
                                    : [@"FAIL " stringByAppendingString:acErr ?: @""]]);
            LPReplay(req, 1, idToken, acToken);
        });
    });
}

#pragma mark - hook NSURLSession

static id LPDataTaskHook(id self, SEL _cmd, NSURLRequest *req, id completion) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    if (!LPFriendURL(req.URL)) return ((id (*)(id, SEL, NSURLRequest *, id))o)(self, _cmd, req, completion);
    void (^orig)(NSData *, NSURLResponse *, NSError *) = completion;
    id wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        LPHandleFriendResponse(req, data, resp, err);
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
        LPHandleFriendResponse(req, data, resp, err);
        if (orig) orig(data, resp, err);
    };
    return ((id (*)(id, SEL, NSURLRequest *, NSData *, id))o)(self, _cmd, req, body, wrapped);
}

// GTMSessionFetcher — Firebase Functions trên iOS dùng thư viện này
static void LPFetcherStartHook(id self, SEL _cmd, id completion) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    NSURLRequest *req = nil;
    @try { req = [self valueForKey:@"request"]; } @catch (__unused NSException *e) {}
    if (!req || !LPFriendURL(req.URL)) { ((void (*)(id, SEL, id))o)(self, _cmd, completion); return; }
    void (^orig)(NSData *, NSError *) = completion;
    id wrapped = ^(NSData *data, NSError *err) {
        NSURLResponse *resp = nil;
        @try { resp = [self valueForKey:@"response"]; } @catch (__unused NSException *e) {}
        LPHandleFriendResponse(req, data, resp, err);
        if (orig) orig(data, err);
    };
    ((void (*)(id, SEL, id))o)(self, _cmd, wrapped);
}

#pragma mark - probe

void LPRunFriendProbe(UIViewController *host) {
    NSMutableString *out = [NSMutableString string];
    [out appendString:LPFriendLogText()];
    [out appendString:@"\n===== probe =====\n"];
    [out appendFormat:@"FIRAuth: %@ | FIRAppCheck: %@\n",
        NSClassFromString(@"FIRAuth") ? @"có" : @"KHÔNG",
        NSClassFromString(@"FIRAppCheck") ? @"có" : @"KHÔNG"];
    LPFetchIDToken(^(NSString *idToken, NSString *idErr) {
        [out appendFormat:@"ID token: %@\n", idToken ? [NSString stringWithFormat:@"ok %lu ký tự", (unsigned long)idToken.length] : idErr];
        LPFetchAppCheckToken(^(NSString *acToken, NSString *acErr) {
            [out appendFormat:@"AppCheck: %@\n", acToken ? [NSString stringWithFormat:@"ok %lu ký tự", (unsigned long)acToken.length] : acErr];
            LPShowText(host, @"Chẩn đoán kết bạn", out);
        });
    });
}

#pragma mark - install

void LPInstallFriendTools(void) {
    if (gFriendHooks) return;
    gFriendHooks = YES;

    Class sess = NSClassFromString(@"NSURLSession");
    SEL s1 = @selector(dataTaskWithRequest:completionHandler:);
    Method m1 = class_getInstanceMethod(sess, s1);
    if (m1) { LPSetOrigIMP(sess, s1, method_getImplementation(m1)); method_setImplementation(m1, (IMP)LPDataTaskHook); LPLog(@"[friend] hook dataTask"); }

    SEL s2 = @selector(uploadTaskWithRequest:fromData:completionHandler:);
    Method m2 = class_getInstanceMethod(sess, s2);
    if (m2) { LPSetOrigIMP(sess, s2, method_getImplementation(m2)); method_setImplementation(m2, (IMP)LPUploadTaskHook); LPLog(@"[friend] hook uploadTask"); }

    Class fetcher = NSClassFromString(@"GTMSessionFetcher");
    if (fetcher) {
        SEL s3 = NSSelectorFromString(@"startWithCompletionHandler:");
        Method m3 = class_getInstanceMethod(fetcher, s3);
        if (m3) {
            LPSetOrigIMP(fetcher, s3, method_getImplementation(m3));
            method_setImplementation(m3, (IMP)LPFetcherStartHook);
            LPLog(@"[friend] hook GTMSessionFetcher");
        }
    }
    LPAddFriendLog(@"bộ chẩn đoán kết bạn đã bật");
}
