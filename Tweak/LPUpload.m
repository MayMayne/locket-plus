// ============================================================================
//  LPUpload.m — nâng timeout upload video lên Firebase Storage
//
//  BÁM SÁT MHVideoPipeline._FetchBegin @0x8850 (đọc từng lệnh assembly).
//
//  Nó hook -[GTMSessionFetcher beginFetchWithCompletionHandler:] và:
//    1. lấy fetcher.request
//    2. lọc: host == firebasestorage.googleapis.com
//              hoặc storage.googleapis.com
//            VÀ path hasPrefix "/v0/b/locket-video/"
//              hoặc "/upload/storage/v1/b/locket-video/"
//              hoặc "/locket-video/"
//            VÀ HTTPMethod == POST hoặc PUT (hoặc PATCH)
//    3. nếu timeoutInterval < 288.0  → mutableCopy request,
//       setTimeoutInterval:288.0, setRequest:
//    4. gọi IMP gốc
//
//  288.0 = 0x4072000000000000 tại 0x8ad0-0x8ad8.
//
//  VÌ SAO CẦN: video 60s / 15MB upload qua mạng 4G mất hơn 60 giây. Timeout
//  mặc định của NSURLRequest là 60s → request bị huỷ giữa chừng → "không up
//  được video". Đây là lỗi tôi bỏ sót ở bản v6.0.
// ============================================================================

#import "LPCommon.h"
#import <objc/message.h>
#import <objc/runtime.h>

static const void *kLPFetchHandled = &kLPFetchHandled;

static BOOL LPIsVideoUpload(NSURLRequest *req) {
    if (!req) return NO;

    NSURL *url = req.URL;
    NSString *host = url.host.lowercaseString ?: @"";
    BOOL okHost = [host isEqualToString:@"firebasestorage.googleapis.com"] ||
                  [host isEqualToString:@"storage.googleapis.com"];
    if (!okHost) return NO;

    NSString *path = url.path ?: @"";
    BOOL okPath = [path hasPrefix:@"/v0/b/locket-video/"] ||
                  [path hasPrefix:@"/upload/storage/v1/b/locket-video/"] ||
                  [path hasPrefix:@"/locket-video/"];
    if (!okPath) return NO;

    NSString *m = req.HTTPMethod.uppercaseString ?: @"";
    if (!([m isEqualToString:@"POST"] || [m isEqualToString:@"PUT"] ||
          [m isEqualToString:@"PATCH"])) return NO;

    return YES;
}

typedef void (^LPFetchCompletion)(NSData *, NSURLResponse *, NSError *);

static void LPBeginFetch(id self, SEL _cmd, LPFetchCompletion handler) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    @try {
        if (objc_getAssociatedObject(self, kLPFetchHandled)) {
            ((void (*)(id, SEL, LPFetchCompletion))o)(self, _cmd, handler);
            return;
        }

        if (![self respondsToSelector:@selector(request)]) {
            ((void (*)(id, SEL, LPFetchCompletion))o)(self, _cmd, handler);
            return;
        }

        NSURLRequest *req = ((id (*)(id, SEL))objc_msgSend)(self, @selector(request));
        if (![req isKindOfClass:[NSURLRequest class]] || !LPIsVideoUpload(req)) {
            ((void (*)(id, SEL, LPFetchCompletion))o)(self, _cmd, handler);
            return;
        }

        objc_setAssociatedObject(self, kLPFetchHandled, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        double want = [[LPConfig shared] dbl:@"uploadTimeout" fallback:288.0];
        if (!isfinite(want) || want < 30 || want > 3600) want = 288.0;

        double cur = req.timeoutInterval;
        if (isfinite(cur) && cur < want) {
            NSMutableURLRequest *m = [req mutableCopy];
            if (m) {
                m.timeoutInterval = want;
                ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setRequest:), m);
                LPLog(@"[upload] timeout %.0fs → %.0fs (%@)",
                      cur, want, req.URL.path.lastPathComponent);
            }
        }
    } @catch (NSException *e) {
        LPLog(@"[upload] lỗi: %@", e.reason);
    }

    ((void (*)(id, SEL, LPFetchCompletion))o)(self, _cmd, handler);
}

void LPInstallUpload(void) {
    if (![[LPConfig shared] flag:@"uploadFix" fallback:YES]) return;

    Class g = NSClassFromString(@"GTMSessionFetcher");
    if (!g) {
        // Firebase nạp muộn — thử lại vài lần.
        for (int i = 1; i <= 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                Class c = NSClassFromString(@"GTMSessionFetcher");
                if (!c) return;
                BOOL ok = LPHookMethod(c, @selector(beginFetchWithCompletionHandler:),
                                       (IMP)LPBeginFetch, NULL);
                LPLog(@"[upload] hook GTMSessionFetcher (muộn) = %d", ok);
            });
        }
        return;
    }

    BOOL ok = LPHookMethod(g, @selector(beginFetchWithCompletionHandler:),
                           (IMP)LPBeginFetch, NULL);
    LPLog(@"[upload] hook GTMSessionFetcher = %d", ok);
}
