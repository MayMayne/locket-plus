// ============================================================================
//  LPMedia.m — trần quay, mic, tỉ lệ khung, upload
//
//  BÀI HỌC TỪ BẢN v5.0–v5.7 (user báo: "chỉ có Gold, không quay được vid,
//  không up được vid"): 3 thứ tôi TỰ THÊM đã phá camera và export. Không có
//  thứ nào trong 4 dylib mẫu:
//
//  1. `initWithAsset:presetName:` HẠ preset xuống 1280x720.
//     → Locket tạo session với preset riêng; ta đổi preset thì renderSize của
//       composition không khớp → export FAIL → up video thất bại.
//     → ĐÃ BỎ. Không đụng preset nữa.
//
//  2. `fileLengthLimit` = 15MB cho clip ngắn.
//     → fileLengthLimit KHÔNG phải "nén cho vừa". Vượt ngưỡng là export
//       FAIL ngay, không phải file nhỏ đi. Video 60s luôn > 15MB.
//     → ĐÃ SỬA: chỉ NÂNG, không bao giờ hạ.
//
//  3. Thêm mic input vào AVCaptureSession trong `startRunning`.
//     → beginConfiguration/addInput/commitConfiguration đổi graph của session
//       mà Locket đã dựng sẵn → AVCaptureMovieFileOutput mất connection →
//       bấm quay là fail.
//     → ĐÃ TẮT mặc định. Bật bằng `addMicInput = true` khi thật sự cần.
//
//  MẶC ĐỊNH GIỜ LÀ "SAFE MODE": chỉ 3 setter trần, y như 4 dylib mẫu làm.
//  Mọi thứ rủi ro (mic, composition) phải bật rõ ràng trong config.
//
//  SỰ THẬT về MHVideoPipeline (đọc từng lệnh assembly):
//    • _Configure @0x8d88: setFileLengthLimit 0x600000 = 6 MB cho MỌI export.
//      Đây là lý do dylib mẫu NÉN được — nó chấp nhận export fail với video
//      dài, và Locket tự chia nhỏ. Ta KHÔNG làm vậy.
//    • Nó KHÔNG hook setMaxRecordedDuration / setMaxRecordedFileSize
//      → nó KHÔNG nâng trần quay. Trần quay là việc của ta.
//    • _FitComposition @0x99e4 dựng composition đệm khung — chỉ dùng khi
//      người dùng chọn tỉ lệ, không phải mặc định.
//
//  NGUYÊN TẮC ABI: KHÔNG hook getter trả struct > 16 byte. Chỉ hook SETTER
//  nhận struct làm THAM SỐ.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/message.h>
#import <math.h>

static BOOL gMediaInstalled = NO;

#pragma mark - chế độ quay

static double LPEffectiveRecordSeconds(void) {
    if ([[LPConfig shared] flag:@"quickMode" fallback:NO]) {
        return MAX(5.0, [[LPConfig shared] dbl:@"quickRecordSeconds" fallback:60.0]);
    }
    // Bật quick mode bằng file đánh dấu, khỏi phải sửa plist.
    if ([[NSFileManager defaultManager] fileExistsAtPath:LPPath(@"quick.on")]) {
        return MAX(5.0, [[LPConfig shared] dbl:@"quickRecordSeconds" fallback:60.0]);
    }
    return LPMaxRecordSeconds();
}

#pragma mark - AVCaptureMovieFileOutput: trần quay

static void LPMaxDuration(id self, SEL _cmd, CMTime t) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    double want = LPEffectiveRecordSeconds();
    double real = CMTimeGetSeconds(t);
    if (isfinite(real) && real > 0 && real < want) {
        LPLog(@"[media] maxRecordedDuration %.0fs → %.0fs", real, want);
    }
    ((void (*)(id, SEL, CMTime))o)(self, _cmd, CMTimeMakeWithSeconds(want, 600));
}

static void LPMaxFileSize(id self, SEL _cmd, long long size) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    long long want = (long long)LPMaxRecordBytes();
    if (size > 0 && size < want) {
        LPLog(@"[media] maxRecordedFileSize %lld → %lld", size, want);
    }
    ((void (*)(id, SEL, long long))o)(self, _cmd, want);
}

#pragma mark - UIImagePickerController (đường chọn video cũ)

static void LPPickerMaxDuration(id self, SEL _cmd, double secs) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, double))o)(self, _cmd, LPUploadSeconds());
}

#pragma mark - AVAssetExportSession: CHỈ NÂNG giới hạn

// fileLengthLimit là NGƯỠNG CỨNG: vượt là export FAIL, không phải file nhỏ đi.
// Vì vậy chỉ được NÂNG (để video 10 phút không bị chặn), KHÔNG BAO GIỜ HẠ.
// Bản v5.0–v5.7 hạ xuống 15MB cho clip ngắn → mọi video 60s đều fail → không
// up được video.
static void LPExportFileLengthLimit(id self, SEL _cmd, long long limit) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    long long want = (long long)LPMaxRecordBytes();
    long long use = (limit > 0 && limit < want) ? want : limit;
    if (use != limit) LPLog(@"[media] fileLengthLimit %lld → %lld (nâng)", limit, use);
    ((void (*)(id, SEL, long long))o)(self, _cmd, use);
}

#pragma mark - mic (tuỳ chọn, mặc định TẮT)

// Đổi graph của AVCaptureSession mà Locket đã dựng → AVCaptureMovieFileOutput
// mất connection → bấm quay là fail. Đây là lý do "không quay được vid".
//
// Chỉ chạy khi `addMicInput = true` VÀ session chưa chạy VÀ chưa có audio.
// Mỗi session chỉ thử một lần (associated object).
static const void *kLPMicTried = &kLPMicTried;

static void LPEnsureMicInput(id session) {
    if (!session) return;
    if (![[LPConfig shared] flag:@"addMicInput" fallback:NO]) return;
    if (objc_getAssociatedObject(session, kLPMicTried)) return;
    objc_setAssociatedObject(session, kLPMicTried, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    @try {
        if ([session respondsToSelector:@selector(isRunning)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(session, @selector(isRunning))) {
            return;                       // đang chạy → không được sửa graph
        }

        SEL selInputs = @selector(inputs);
        if (![session respondsToSelector:selInputs]) return;

        NSArray *inputs = ((NSArray *(*)(id, SEL))objc_msgSend)(session, selInputs);
        if ([inputs isKindOfClass:[NSArray class]]) {
            for (id input in inputs) {
                NSArray *ports = ((NSArray *(*)(id, SEL))objc_msgSend)(input, @selector(ports));
                if (![ports isKindOfClass:[NSArray class]]) continue;
                for (id port in ports) {
                    NSString *t = ((id (*)(id, SEL))objc_msgSend)(port, @selector(mediaType));
                    if ([t isEqualToString:AVMediaTypeAudio]) return;   // đã có mic
                }
            }
        }

        AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        if (!mic) return;

        NSError *e = nil;
        AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:mic error:&e];
        if (!in) { LPLog(@"[media] mic input lỗi: %@", e.localizedDescription); return; }

        if ([session respondsToSelector:@selector(canAddInput:)] &&
            !((BOOL (*)(id, SEL, id))objc_msgSend)(session, @selector(canAddInput:), in)) {
            LPLog(@"[media] canAddInput: mic = NO");
            return;
        }

        ((void (*)(id, SEL))objc_msgSend)(session, @selector(beginConfiguration));
        BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(session, @selector(addInput:), in);
        ((void (*)(id, SEL))objc_msgSend)(session, @selector(commitConfiguration));
        LPLog(@"[media] thêm micro: %d", ok);
    } @catch (NSException *e) {
        LPLog(@"[media] mic: %@", e.reason);
    }
}

static void LPStartRunning(id self, SEL _cmd) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    @try { LPEnsureMicInput(self); } @catch (__unused NSException *e) {}
    ((void (*)(id, SEL))o)(self, _cmd);
}

#pragma mark - tỉ lệ khung

// "auto"  → KHÔNG đụng gì (mặc định — giữ nguyên hành vi của Locket)
// "9:16"  → khung dọc  (người dùng gọi là 6:19)
// "16:9"  → khung ngang (người dùng gọi là 19:6)
// "1:1"   → vuông
// "ask"   → hỏi mỗi lần export
static BOOL LPRatioValue(NSString *s, double *out) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return NO;
    if ([s isEqualToString:@"auto"] || [s isEqualToString:@"ask"]) return NO;

    NSArray *parts = [s componentsSeparatedByString:@":"];
    if (parts.count != 2) return NO;
    double w = [parts[0] doubleValue];
    double h = [parts[1] doubleValue];
    if (!isfinite(w) || !isfinite(h) || w <= 0 || h <= 0) return NO;
    *out = w / h;
    return YES;
}

static CGSize LPEvenSize(CGSize s, double maxDim) {
    CGFloat w = s.width, h = s.height;
    if (!isfinite(w) || !isfinite(h) || w < 2 || h < 2) return CGSizeZero;

    CGFloat longSide = MAX(w, h);
    if (longSide > maxDim) {
        CGFloat k = maxDim / longSide;
        w *= k; h *= k;
    }
    // H.264 yêu cầu chiều chẵn.
    w = floor(w / 2.0) * 2.0;
    h = floor(h / 2.0) * 2.0;
    if (w < 2) w = 2;
    if (h < 2) h = 2;
    return CGSizeMake(w, h);
}

// Dựng composition đệm khung — tương đương _FitComposition @0x99e4.
static AVMutableVideoComposition *LPFitComposition(AVAsset *asset, double ratio) {
    if (!asset || ratio <= 0) return nil;

    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (![tracks isKindOfClass:[NSArray class]] || !tracks.count) return nil;
    AVAssetTrack *track = tracks.firstObject;
    if (!track) return nil;

    CGSize natural = track.naturalSize;
    CGAffineTransform pref = track.preferredTransform;

    // Kích thước SAU khi xoay theo preferredTransform.
    CGRect orientedRect = CGRectApplyAffineTransform(
        CGRectMake(0, 0, natural.width, natural.height), pref);
    CGSize oriented = CGSizeMake(fabs(orientedRect.size.width),
                                 fabs(orientedRect.size.height));
    if (oriented.width < 2 || oriented.height < 2) return nil;
    if (!isfinite(oriented.width) || !isfinite(oriented.height)) return nil;

    // Canvas: giữ nguyên một chiều của video, chiều kia suy ra từ tỉ lệ.
    CGSize canvas;
    if (oriented.width / oriented.height > ratio) {
        canvas = CGSizeMake(oriented.width, oriented.width / ratio);
    } else {
        canvas = CGSizeMake(oriented.height * ratio, oriented.height);
    }
    double maxDim = [[LPConfig shared] dbl:@"frameMaxDimension" fallback:1920.0];
    if (!isfinite(maxDim) || maxDim < 240) maxDim = 1920;
    canvas = LPEvenSize(canvas, maxDim);
    if (canvas.width < 2 || canvas.height < 2) return nil;

    // Scale để vừa (aspect-fit) rồi canh giữa.
    CGFloat s = MIN(canvas.width / oriented.width, canvas.height / oriented.height);

    CGAffineTransform t = pref;
    t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(s, s));

    CGRect box = CGRectApplyAffineTransform(
        CGRectMake(0, 0, natural.width, natural.height), t);
    t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(-box.origin.x, -box.origin.y));
    t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(
        (canvas.width - box.size.width) / 2.0,
        (canvas.height - box.size.height) / 2.0));

    AVMutableVideoCompositionLayerInstruction *li =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
    [li setTransform:t atTime:kCMTimeZero];

    CMTime dur = asset.duration;
    double durSecs = CMTimeGetSeconds(dur);
    if (!isfinite(durSecs) || durSecs <= 0) return nil;   // asset chưa load xong

    AVMutableVideoCompositionInstruction *ins = [AVMutableVideoCompositionInstruction new];
    ins.timeRange = CMTimeRangeMake(kCMTimeZero, dur);
    ins.layerInstructions = @[li];

    NSString *hex = [[LPConfig shared] str:@"frameBackground" fallback:@"000000"];
    unsigned int rgb = 0;
    if (hex.length == 6) sscanf(hex.UTF8String, "%06x", &rgb);
    ins.backgroundColor = [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                                          green:((rgb >> 8) & 0xff) / 255.0
                                           blue:(rgb & 0xff) / 255.0
                                          alpha:1.0].CGColor;

    AVMutableVideoComposition *vc = [AVMutableVideoComposition videoComposition];
    vc.renderSize = canvas;

    float fps = track.nominalFrameRate;
    if (!isfinite(fps) || fps < 1 || fps > 120) fps = 30;
    vc.frameDuration = CMTimeMake(1, (int32_t)lroundf(fps));
    vc.instructions = @[ins];

    LPLog(@"[media] khung %.0fx%.0f (gốc %.0fx%.0f, tỉ lệ %.3f) @%.0ffps",
          canvas.width, canvas.height, oriented.width, oriented.height, ratio, fps);
    return vc;
}

static void LPApplyComposition(id session, NSString *ratioChoice) {
    if (!session) return;
    if (![[LPConfig shared] flag:@"frameRatioEnabled" fallback:NO]) return;

    double ratio = 0;
    if (!LPRatioValue(ratioChoice, &ratio) || ratio <= 0) return;   // "auto" → không đụng

    @try {
        if (![session respondsToSelector:@selector(asset)]) return;
        AVAsset *asset = ((id (*)(id, SEL))objc_msgSend)(session, @selector(asset));
        if (![asset isKindOfClass:[AVAsset class]]) return;

        // Passthrough KHÔNG hỗ trợ videoComposition — gắn vào là export fail.
        if ([session respondsToSelector:@selector(presetName)]) {
            NSString *preset = ((id (*)(id, SEL))objc_msgSend)(session, @selector(presetName));
            if ([preset isEqualToString:AVAssetExportPresetPassthrough]) {
                LPLog(@"[media] passthrough → bỏ qua composition");
                return;
            }
        }

        // Chỉ gắn composition khi duration đã load — nếu không thì bỏ qua,
        // export vẫn chạy bình thường (thà mất khung còn hơn mất video).
        double d = CMTimeGetSeconds(asset.duration);
        if (!isfinite(d) || d <= 0) {
            LPLog(@"[media] duration chưa load → bỏ qua composition");
            return;
        }

        AVMutableVideoComposition *vc = LPFitComposition(asset, ratio);
        if (!vc) { LPLog(@"[media] không dựng được composition"); return; }

        ((void (*)(id, SEL, id))objc_msgSend)(session, @selector(setVideoComposition:), vc);
    } @catch (NSException *e) {
        LPLog(@"[media] composition lỗi: %@", e.reason);
    }
}

#pragma mark - hỏi tỉ lệ

static void LPAskRatioOnMain(void (^done)(NSString *choice));

static void LPAskRatio(void (^done)(NSString *choice)) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LPAskRatioOnMain(done); });
        return;
    }
    LPAskRatioOnMain(done);
}

static void LPAskRatioOnMain(void (^done)(NSString *choice)) {
    // Không trả lời trong 20s (app bị đẩy nền, alert bị che) → chạy tiếp "auto".
    // KHÔNG được treo luồng export.
    __block BOOL answered = NO;
    void (^finish)(NSString *) = ^(NSString *c) {
        if (answered) return;
        answered = YES;
        if (done) done(c ?: @"auto");
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(@"auto"); });

    UIWindow *win = nil;
    @try {
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { win = w; break; }
                }
                if (win) break;
            }
        }
        if (!win) win = UIApplication.sharedApplication.keyWindow;
    } @catch (__unused NSException *e) {}

    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) { finish(@"auto"); return; }

    @try {
        UIAlertController *a = [UIAlertController
            alertControllerWithTitle:@"Khung hình video"
                             message:@"Thêm nền đệm để Locket không cắt vuông."
                      preferredStyle:UIAlertControllerStyleActionSheet];

        NSArray *opts = @[@[@"Gốc · không đệm",   @"auto"],
                          @[@"16:9 · khung ngang", @"16:9"],
                          @[@"9:16 · khung dọc",   @"9:16"],
                          @[@"1:1 · vuông",        @"1:1"]];
        for (NSArray *o in opts) {
            [a addAction:[UIAlertAction actionWithTitle:o[0]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *x) { finish(o[1]); }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Huỷ"
                                             style:UIAlertActionStyleCancel
                                           handler:^(__unused UIAlertAction *x) { finish(@"auto"); }]];

        a.popoverPresentationController.sourceView = vc.view;
        a.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);

        [vc presentViewController:a animated:YES completion:nil];
    } @catch (NSException *e) {
        LPLog(@"[media] alert tỉ lệ lỗi: %@", e.reason);
        finish(@"auto");
    }
}

#pragma mark - export

typedef void (^LPExportCompletion)(void);

static const void *kLPPrepared = &kLPPrepared;

static void LPExportAsync(id self, SEL _cmd, LPExportCompletion handler) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    // Mỗi session chỉ chuẩn bị MỘT lần.
    if (objc_getAssociatedObject(self, kLPPrepared)) {
        ((void (*)(id, SEL, LPExportCompletion))o)(self, _cmd, handler);
        return;
    }
    objc_setAssociatedObject(self, kLPPrepared, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // MẶC ĐỊNH: không đụng gì. Export chạy y như Locket muốn.
    // Chỉ can thiệp khi người dùng bật rõ ràng trong config.
    NSString *choice = [[LPConfig shared] str:@"frameRatioDefault" fallback:@"auto"];
    BOOL wantRatio = [[LPConfig shared] flag:@"frameRatioEnabled" fallback:NO];

    if (!wantRatio || [choice isEqualToString:@"auto"]) {
        ((void (*)(id, SEL, LPExportCompletion))o)(self, _cmd, handler);
        return;
    }

    AVAsset *asset = nil;
    @try {
        if ([self respondsToSelector:@selector(asset)]) {
            id a = ((id (*)(id, SEL))objc_msgSend)(self, @selector(asset));
            if ([a isKindOfClass:[AVAsset class]]) asset = a;
        }
    } @catch (__unused NSException *e) {}

    if (!asset) {
        ((void (*)(id, SEL, LPExportCompletion))o)(self, _cmd, handler);
        return;
    }

    __block BOOL started = NO;
    void (^start)(void) = ^{
        if (started) return;
        started = YES;
        ((void (*)(id, SEL, LPExportCompletion))o)(self, _cmd, handler);
    };

    // Chốt chặn: asset không load xong thì vẫn export, không được treo.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ start(); });

    void (^proceed)(NSString *) = ^(NSString *picked) {
        @try { LPApplyComposition(self, picked); } @catch (__unused NSException *e) {}
        dispatch_async(dispatch_get_main_queue(), ^{ start(); });
    };

    NSArray *keys = @[@"tracks", @"duration"];
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
        BOOL ok = YES;
        for (NSString *k in keys) {
            if ([asset statusOfValueForKey:k error:NULL] != AVKeyValueStatusLoaded) {
                ok = NO;
                break;
            }
        }
        if (!ok) {
            LPLog(@"[media] asset chưa load xong → export nguyên bản");
            dispatch_async(dispatch_get_main_queue(), ^{ start(); });
            return;
        }
        if ([choice isEqualToString:@"ask"]) {
            LPAskRatio(^(NSString *p) { proceed(p); });
        } else {
            proceed(choice);
        }
    }];
}

#pragma mark - install

void LPInstallMedia(void) {
    if (gMediaInstalled) return;
    gMediaInstalled = YES;

    if (![[LPConfig shared] flag:@"mediaEnabled" fallback:YES]) {
        LPLog(@"[media] tắt theo config");
        return;
    }

    // 1. Trần quay — 2 setter, an toàn tuyệt đối (đây là thứ 4 dylib mẫu
    //    KHÔNG làm, và cũng là yêu cầu chính).
    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    BOOL a = LPHookMethodTyped(out, @selector(setMaxRecordedDuration:), "v",
                               (IMP)LPMaxDuration, NULL);
    BOOL b = LPHookMethodTyped(out, @selector(setMaxRecordedFileSize:), "v",
                               (IMP)LPMaxFileSize, NULL);
    LPLog(@"[media] trần quay duration=%d size=%d", a, b);

    // 2. Nâng ngưỡng dung lượng export — chỉ nâng, không hạ.
    Class exp = NSClassFromString(@"AVAssetExportSession");
    BOOL c = LPHookMethodTyped(exp, @selector(setFileLengthLimit:), "v",
                               (IMP)LPExportFileLengthLimit, NULL);
    LPLog(@"[media] fileLengthLimit (nâng) = %d", c);

    // 3. Chọn video từ thư viện.
    Class picker = NSClassFromString(@"UIImagePickerController");
    BOOL d = LPHookMethodTyped(picker, @selector(setVideoMaximumDuration:), "v",
                               (IMP)LPPickerMaxDuration, NULL);
    LPLog(@"[media] picker duration = %d", d);

    // 4. Tuỳ chọn — CHỈ chạy khi bật `experimental = true`.
    //
    // Vì sao cần công tắc riêng: config.plist cũ trên máy đã có
    // `addMicInput = true` và `frameRatioEnabled = true` từ bản v5.0–v5.7.
    // Nếu chỉ đổi giá trị mặc định thì config cũ vẫn bật lại 2 thứ đã phá
    // camera/export. Công tắc mới bắt buộc phải bật tay, nên bản cũ không
    // thể vô tình kích hoạt.
    BOOL experimental = [[LPConfig shared] flag:@"experimental" fallback:NO];

    if (experimental && [[LPConfig shared] flag:@"addMicInput" fallback:NO]) {
        Class cap = NSClassFromString(@"AVCaptureSession");
        BOOL e = LPHookMethod(cap, @selector(startRunning), (IMP)LPStartRunning, NULL);
        LPLog(@"[media] mic (thử nghiệm) = %d", e);
    }

    if (experimental && [[LPConfig shared] flag:@"frameRatioEnabled" fallback:NO]) {
        BOOL f = LPHookMethodTyped(exp, @selector(exportAsynchronouslyWithCompletionHandler:), "v",
                                   (IMP)LPExportAsync, NULL);
        LPLog(@"[media] tỉ lệ khung (thử nghiệm) = %d", f);
    }

    if (!experimental) {
        LPLog(@"[media] chế độ AN TOÀN: chỉ trần quay + nâng ngưỡng dung lượng");
    }

    LPLog(@"[media] trần %.0fs / %.0fMB · upload %.0fs / %.0fMB",
          LPEffectiveRecordSeconds(), LPMaxRecordBytes() / 1048576.0,
          LPUploadSeconds(), LPUploadBytes() / 1048576.0);
}
