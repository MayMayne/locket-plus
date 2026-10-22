// ============================================================================
//  LPMedia.m — trần quay, mic, tỉ lệ khung, upload từ thư viện
//
//  BÁM SÁT MHVideoPipeline.dylib, nhưng sửa đúng 2 chỗ nó làm sai/thiếu:
//
//  SỰ THẬT về MHVideoPipeline (đọc từng lệnh assembly):
//    • _ExportInit @0x8420 hook -[AVAssetExportSession initWithAsset:presetName:]
//      → ladder HẠ CẤP: 1280x720 kiểm TRƯỚC (0x8558), rồi 1920x1080 (0x8590),
//        không có cả hai thì giữ preset gốc (0x85c0).
//    • _Configure @0x8d88: setFileLengthLimit 0x600000 = 6 MB,
//      setShouldOptimizeForNetworkUse YES,
//      setCanPerformMultiplePassesOverSourceMediaData NO.
//    • Nó KHÔNG hook setMaxRecordedDuration / setMaxRecordedFileSize
//      → nó KHÔNG nâng trần quay. Nó nén cho vừa giới hạn upload.
//    • _FitComposition @0x99e4 dựng AVMutableVideoComposition để đệm khung.
//    • Hằng 0x17c88 = 600 KHÔNG phải "600 giây" — đó là timescale của
//      kCMTimeZero, dùng cho setTransform:atTime:. Không liên quan thời lượng.
//
//  LocketPlus làm CẢ HAI, tách bằng config:
//    • maxRecordSeconds / maxRecordBytes  → trần QUAY (mặc định 600s / 500MB)
//    • quickMode + quickRecordSeconds     → chế độ quay nhanh 60s
//    • maxUploadSeconds / maxUploadBytes  → trần khi UP từ thư viện (60s / 15MB)
//    • frameRatioDefault                  → đệm khung 9:16 / 16:9 / 1:1 / 6:19 / 19:6
//
//  NGUYÊN TẮC ABI (đã trả giá bằng 2 bản crash):
//    KHÔNG hook getter trả struct > 16 byte (CMTime, CMTimeRange, CGRect…).
//    Trên arm64 struct > 16 byte trả qua con trỏ ẩn ở x8 — khai báo sai chữ ký
//    là ghi vào thanh ghi rác. Chỉ hook SETTER nhận struct làm THAM SỐ.
//    KHÔNG hook -init… (quy ước +1 của ARC). Cấu hình session ở
//    exportAsynchronouslyWithCompletionHandler: — đúng như _ExportStart @0x86b8.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/message.h>
#import <math.h>

static BOOL gMediaInstalled = NO;
static volatile BOOL gCaptureRunning = NO;

#pragma mark - chế độ quay

static double LPEffectiveRecordSeconds(void) {
    if ([[LPConfig shared] flag:@"quickMode" fallback:NO]) {
        return MAX(5.0, [[LPConfig shared] dbl:@"quickRecordSeconds" fallback:60.0]);
    }
    // Cho phép bật quick mode bằng file đánh dấu, khỏi phải sửa plist.
    if ([[NSFileManager defaultManager] fileExistsAtPath:LPPath(@"quick.on")]) {
        return MAX(5.0, [[LPConfig shared] dbl:@"quickRecordSeconds" fallback:60.0]);
    }
    return LPMaxRecordSeconds();
}

#pragma mark - AVCaptureMovieFileOutput: trần quay

static void LPMaxDuration(id self, SEL _cmd, CMTime t) {
    LPTrace("media.maxDuration");
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
    LPTrace("media.maxFileSize");
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    long long want = (long long)LPMaxRecordBytes();
    if (size > 0 && size < want) {
        LPLog(@"[media] maxRecordedFileSize %lld → %lld", size, want);
    }
    ((void (*)(id, SEL, long long))o)(self, _cmd, want);
}

#pragma mark - mic

static void LPEnsureAudioCategory(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSError *err = nil;
        [s setCategory:AVAudioSessionCategoryPlayAndRecord
                  mode:AVAudioSessionModeVideoRecording
               options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                       AVAudioSessionCategoryOptionAllowBluetooth
                 error:&err];
        if (err) { LPLog(@"[media] audio category: %@", err.localizedDescription); return; }
        [s setActive:YES withOptions:0 error:&err];
        if (err) LPLog(@"[media] audio active: %@", err.localizedDescription);
    } @catch (NSException *e) {
        LPLog(@"[media] audio: %@", e.reason);
    }
}

// Thêm micro vào session nếu chưa có. Bọc trong begin/commitConfiguration
// để không phá cấu hình đang chạy của app.
static void LPEnsureMicInput(id session) {
    if (!session) return;
    if (![[LPConfig shared] flag:@"addMicInput" fallback:YES]) return;

    @try {
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
        if (!mic) { LPLog(@"[media] không có thiết bị micro"); return; }

        NSError *e = nil;
        AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:mic error:&e];
        if (!in) { LPLog(@"[media] tạo mic input lỗi: %@", e.localizedDescription); return; }

        if ([session respondsToSelector:@selector(canAddInput:)]) {
            BOOL can = ((BOOL (*)(id, SEL, id))objc_msgSend)(session, @selector(canAddInput:), in);
            if (!can) { LPLog(@"[media] canAddInput: mic = NO"); return; }
        }

        if ([session respondsToSelector:@selector(beginConfiguration)]) {
            ((void (*)(id, SEL))objc_msgSend)(session, @selector(beginConfiguration));
        }
        BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(session, @selector(addInput:), in);
        if ([session respondsToSelector:@selector(commitConfiguration)]) {
            ((void (*)(id, SEL))objc_msgSend)(session, @selector(commitConfiguration));
        }
        LPLog(@"[media] thêm micro vào session quay: %d", ok);
    } @catch (NSException *e) {
        LPLog(@"[media] mic: %@", e.reason);
    }
}

static void (*gOrigStartRunning)(id, SEL);
static void LPStartRunning(id self, SEL _cmd) {
    LPTrace("media.startRunning");
    @try {
        LPEnsureMicInput(self);
        if ([[LPConfig shared] flag:@"keepAudioSession" fallback:YES]) LPEnsureAudioCategory();
    } @catch (__unused NSException *e) {}
    if (gOrigStartRunning) gOrigStartRunning(self, _cmd);
}

static void (*gOrigStopRunning)(id, SEL);
static void LPStopRunning(id self, SEL _cmd) {
    if (gOrigStopRunning) gOrigStopRunning(self, _cmd);
}

// Cờ GHI HÌNH thật — chỉ bật giữa startRecording… và stopRecording.
// Dùng cờ này thay cho "session đang chạy": session chạy không có nghĩa là
// đang ghi, và giữ audio session sống khi chỉ đang xem trước sẽ bật micro
// vô ích (đèn cam/mic sáng, nhạc nền bị ngắt).
static volatile BOOL gRecording = NO;
static NSTimeInterval gRecordingDeadline = 0;

static void (*gOrigStartRecording)(id, SEL, NSURL *, id);
static void LPStartRecording(id self, SEL _cmd, NSURL *url, id delegate) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    gRecording = YES;
    gRecordingDeadline = [NSDate timeIntervalSinceReferenceDate] + LPEffectiveRecordSeconds() + 30.0;
    LPTrace("media.startRecording");
    ((void (*)(id, SEL, NSURL *, id))o)(self, _cmd, url, delegate);
}

static void (*gOrigStopRecording)(id, SEL);
static void LPStopRecording(id self, SEL _cmd) {
    gRecording = NO;
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL))o)(self, _cmd);
}

// Giữ audio session sống CHỈ khi đang ghi hình thật.
static BOOL (*gOrigSetActive)(id, SEL, BOOL, NSUInteger, NSError **);
static BOOL LPSetActive(id self, SEL _cmd, BOOL active, NSUInteger opts, NSError **err) {
    if (!active && gRecording &&
        [NSDate timeIntervalSinceReferenceDate] < gRecordingDeadline &&
        [[LPConfig shared] flag:@"keepAudioSession" fallback:YES]) {
        LPTrace("media.keepAudioSession");
        return YES;
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    return o ? ((BOOL (*)(id, SEL, BOOL, NSUInteger, NSError **))o)(self, _cmd, active, opts, err)
             : NO;
}

#pragma mark - tỉ lệ khung

// "auto"  → không đụng gì (giữ nguyên hành vi app)
// "9:16"  → khung dọc  (người dùng gọi là 6:19)
// "16:9"  → khung ngang (người dùng gọi là 19:6)
// "1:1"   → vuông (định dạng feed của Locket)
// "ask"   → hỏi bằng alert mỗi lần export
static double LPRatioValue(NSString *s, double *out) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return 0;
    if ([s isEqualToString:@"auto"] || [s isEqualToString:@"ask"]) return 0;

    NSArray *parts = [s componentsSeparatedByString:@":"];
    if (parts.count != 2) return 0;
    double w = [parts[0] doubleValue];
    double h = [parts[1] doubleValue];
    if (!isfinite(w) || !isfinite(h) || w <= 0 || h <= 0) return 0;
    *out = w / h;
    return 1;
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
// Trả nil nếu không làm được (asset không có video track, kích thước vô lý…).
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
    CGFloat sx = canvas.width / oriented.width;
    CGFloat sy = canvas.height / oriented.height;
    CGFloat s = MIN(sx, sy);

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

    AVMutableVideoCompositionInstruction *ins = [AVMutableVideoCompositionInstruction new];
    CMTime dur = asset.duration;
    double durSecs = CMTimeGetSeconds(dur);
    if (!isfinite(durSecs) || durSecs <= 0) {
        // Asset chưa load xong duration → composition sẽ hỏng. Bỏ qua.
        return nil;
    }
    ins.timeRange = CMTimeRangeMake(kCMTimeZero, dur);
    ins.layerInstructions = @[li];

    // Màu nền của phần đệm. MHVideoPipeline dùng màu tối; cho cấu hình được.
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

#pragma mark - hỏi tỉ lệ (kiểu _ChooseRatio của mẫu)

static void LPAskRatioOnMain(void (^done)(NSString *choice));

static void LPAskRatio(void (^done)(NSString *choice)) {
    // UIAlertController PHẢI present trên main thread. exportAsynchronously có
    // thể được gọi từ background → dispatch, không present tại chỗ.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LPAskRatioOnMain(done); });
        return;
    }
    LPAskRatioOnMain(done);
}

static void LPAskRatioOnMain(void (^done)(NSString *choice)) {
    // Chỉ định nghĩa MỘT lần cho mỗi lần gọi. Nếu người dùng không trả lời
    // trong 20s (app bị đẩy nền, alert bị che), tự chạy tiếp với "auto" —
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
                             message:@"Tự nhận ngang/dọc, giữ trọn hình. Thêm nền đệm để Locket không cắt vuông lần nữa."
                      preferredStyle:UIAlertControllerStyleActionSheet];

        NSArray *opts = @[@[@"Gốc · tự động vừa khung", @"auto"],
                          @[@"16:9 · khung ngang",       @"16:9"],
                          @[@"9:16 · khung dọc",         @"9:16"],
                          @[@"1:1 · vuông",              @"1:1"]];
        for (NSArray *o in opts) {
            [a addAction:[UIAlertAction actionWithTitle:o[0]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *x) { finish(o[1]); }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Huỷ"
                                             style:UIAlertActionStyleCancel
                                           handler:^(__unused UIAlertAction *x) { finish(@"auto"); }]];

        // iPad: action sheet cần sourceView, nếu không sẽ crash.
        a.popoverPresentationController.sourceView = vc.view;
        a.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);

        [vc presentViewController:a animated:YES completion:nil];
    } @catch (NSException *e) {
        LPLog(@"[media] alert tỉ lệ lỗi: %@", e.reason);
        finish(@"auto");
    }
}

#pragma mark - preset ladder (bám sát _ExportInit @0x8420 của mẫu)

// Mẫu hook -[AVAssetExportSession initWithAsset:presetName:] và HẠ preset:
//   1. AVAssetExportPreset1280x720   (kiểm trước — 0x8558)
//   2. AVAssetExportPreset1920x1080  (0x8590)
//   3. không có cả hai → giữ preset gốc (0x85c0)
// Đó là cách video dài thực sự vừa giới hạn upload, vì fileLengthLimit chỉ là
// gợi ý — AVFoundation có thể bỏ qua và export ra file to hơn.
//
// Hook họ "init" dưới ARC: PHẢI khai báo ns_returns_retained ở CẢ hàm hook VÀ
// con trỏ hàm gọi IMP gốc. Nếu thiếu, ARC giả định +0 ở một trong hai phía →
// over-release (crash) hoặc leak. Đây chính là lỗi làm v1.x chết, không phải
// "không được hook init".
typedef id (*LPInitIMP)(id, SEL, id, id) __attribute__((ns_returns_retained));

static NSArray<NSString *> *LPPresetLadder(void) {
    return @[@"AVAssetExportPreset1280x720",
             @"AVAssetExportPreset1920x1080"];
}

static NSString *LPChoosePreset(AVAsset *asset, NSString *requested) {
    if (![[LPConfig shared] flag:@"compressShortUploads" fallback:YES]) return requested;
    if (!asset || ![requested isKindOfClass:[NSString class]]) return requested;

    @try {
        // CHỈ áp cho asset CÓ video track. Export audio/ảnh không được đụng.
        NSArray *vt = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (![vt isKindOfClass:[NSArray class]] || !vt.count) return requested;

        // CHỈ hạ preset cho clip NGẮN (mục tiêu 15MB / 60s ≈ 2 Mbps).
        // Video quay dài 10 phút có ngân sách 500MB ≈ 6.7 Mbps — 1080p vẫn vừa,
        // hạ xuống 720p chỉ làm mất chi tiết mà không cần thiết.
        double d = CMTimeGetSeconds(asset.duration);
        if (!isfinite(d) || d <= 0) return requested;
        if (d > LPUploadSeconds() + 0.5) return requested;
    } @catch (__unused NSException *e) { return requested; }

    @try {
        NSArray *compatible = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
        if (![compatible isKindOfClass:[NSArray class]] || !compatible.count) return requested;

        for (NSString *p in LPPresetLadder()) {
            if ([compatible containsObject:p]) {
                if (![p isEqualToString:requested]) {
                    LPLog(@"[media] preset %@ → %@ (clip ngắn, nén vừa 15MB)", requested, p);
                }
                return p;
            }
        }
    } @catch (NSException *e) { LPLog(@"[media] chọn preset lỗi: %@", e.reason); }
    return requested;
}

static id LPExportInit(id self, SEL _cmd, AVAsset *asset, NSString *preset)
    __attribute__((ns_returns_retained));

static id LPExportInit(id self, SEL _cmd, AVAsset *asset, NSString *preset) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    NSString *use = LPChoosePreset(asset, preset);
    return ((LPInitIMP)o)(self, _cmd, asset, use);
}

#pragma mark - AVAssetExportSession

static void LPApplyComposition(id session, NSString *ratioChoice) {
    if (!session) return;
    if (![[LPConfig shared] flag:@"frameRatioEnabled" fallback:YES]) return;

    double ratio = 0;
    if (!LPRatioValue(ratioChoice, &ratio) || ratio <= 0) return;

    @try {
        if (![session respondsToSelector:@selector(asset)]) return;
        AVAsset *asset = ((id (*)(id, SEL))objc_msgSend)(session, @selector(asset));
        if (![asset isKindOfClass:[AVAsset class]]) return;

        // Passthrough KHÔNG hỗ trợ videoComposition — gắn vào là export fail
        // với lỗi khó hiểu. Bỏ qua, giữ nguyên hành vi gốc.
        if ([session respondsToSelector:@selector(presetName)]) {
            NSString *preset = ((id (*)(id, SEL))objc_msgSend)(session, @selector(presetName));
            if ([preset isEqualToString:AVAssetExportPresetPassthrough]) {
                LPLog(@"[media] preset passthrough → không gắn composition");
                return;
            }
        }

        AVMutableVideoComposition *vc = LPFitComposition(asset, ratio);
        if (!vc) { LPLog(@"[media] không dựng được composition"); return; }

        // Không đụng audio: AVMutableVideoComposition chỉ mô tả phần hình,
        // track âm thanh vẫn đi qua export session bình thường.
        ((void (*)(id, SEL, id))objc_msgSend)(session, @selector(setVideoComposition:), vc);
    } @catch (NSException *e) {
        LPLog(@"[media] composition lỗi: %@", e.reason);
    }
}

// _ExportStart @0x86b8 của mẫu: đọc associated object, nếu chưa xử lý thì
// dispatch_async về main rồi mới gọi IMP gốc. Ta cấu hình ngay trên luồng gọi
// (setVideoComposition: an toàn trước khi export chạy).
typedef void (^LPExportCompletion)(void);

static void LPExportAsync(id self, SEL _cmd, LPExportCompletion handler) {
    LPTrace("media.exportAsync");
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    // Đọc duration asset để quyết định ngân sách dung lượng.
    double assetSecs = 0;
    @try {
        if ([self respondsToSelector:@selector(asset)]) {
            AVAsset *asset = ((id (*)(id, SEL))objc_msgSend)(self, @selector(asset));
            if ([asset isKindOfClass:[AVAsset class]]) {
                double d = CMTimeGetSeconds(asset.duration);
                if (isfinite(d) && d > 0) assetSecs = d;
            }
        }
    } @catch (__unused NSException *e) {}

    NSString *choice = [[LPConfig shared] str:@"frameRatioDefault" fallback:@"auto"];

    if ([choice isEqualToString:@"ask"]) {
        static BOOL askedThisSession = NO;
        if (!askedThisSession) {
            askedThisSession = YES;
            __block BOOL started = NO;
            LPAskRatio(^(NSString *picked) {
                if (started) return;
                started = YES;
                LPApplyComposition(self, picked);
                ((void (*)(id, SEL, LPExportCompletion))o)(self, _cmd, handler);
            });
            return;
        }
        choice = @"auto";
    }

    LPApplyComposition(self, choice);

    @try {
        // Ngân sách dung lượng:
        //   clip ngắn (≤ maxUploadSeconds)  → nén về maxUploadBytes (15MB)
        //   video dài (quay 10 phút)        → trần quay maxRecordBytes (500MB)
        // Nhờ vậy "quay 10 phút 500MB" và "up 60s 15MB" cùng đúng.
        long long budget;
        double shortLimit = LPUploadSeconds();
        if (assetSecs > 0 && assetSecs <= shortLimit + 0.5 &&
            [[LPConfig shared] flag:@"compressShortUploads" fallback:YES]) {
            budget = (long long)LPUploadBytes();
        } else {
            budget = (long long)LPMaxRecordBytes();
        }

        SEL selLimit = @selector(setFileLengthLimit:);
        if ([self respondsToSelector:selLimit]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(self, selLimit, budget);
        }
        if ([self respondsToSelector:@selector(setShouldOptimizeForNetworkUse:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self,
                @selector(setShouldOptimizeForNetworkUse:), YES);
        }
        LPLog(@"[media] export %.1fs → ngân sách %.1fMB", assetSecs, budget / 1048576.0);
    } @catch (__unused NSException *e) {}

    ((void (*)(id, SEL, LPExportCompletion))o)(self, _cmd, handler);
}

// Cắt bớt khi video dài hơn trần upload.
//
// MẶC ĐỊNH TẮT. Lý do: hook này chạy cho MỌI export, kể cả video vừa quay
// 10 phút — cắt nó về 60s là phá đúng tính năng người dùng yêu cầu. Chỉ bật
// khi thật sự cần ép vừa giới hạn server.
static void LPExportTimeRange(id self, SEL _cmd, CMTimeRange r) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    CMTimeRange use = r;
    @try {
        if ([[LPConfig shared] flag:@"trimToUpload" fallback:NO]) {
            double d = CMTimeGetSeconds(r.duration);
            double limit = LPUploadSeconds();
            if (isfinite(d) && d > 0 && d > limit + 0.05) {
                use = CMTimeRangeMake(r.start, CMTimeMakeWithSeconds(limit, 600));
                LPLog(@"[media] timeRange %.1fs → %.1fs (trimToUpload)", d, limit);
            }
        }
    } @catch (__unused NSException *e) {}

    ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, use);
}

// Nâng trần dung lượng, không hạ.
static void LPExportFileLengthLimit(id self, SEL _cmd, long long limit) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    long long want = (long long)LPMaxRecordBytes();
    long long use = (limit > 0 && limit < want) ? want : limit;
    if (use != limit) LPLog(@"[media] fileLengthLimit %lld → %lld", limit, use);
    ((void (*)(id, SEL, long long))o)(self, _cmd, use);
}

// UIImagePickerController (đường chọn video cũ của Locket).
static void LPPickerMaxDuration(id self, SEL _cmd, double secs) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, double))o)(self, _cmd, LPUploadSeconds());
}

#pragma mark - install

void LPInstallMedia(void) {
    if (gMediaInstalled) return;
    gMediaInstalled = YES;

    if (![[LPConfig shared] flag:@"mediaEnabled" fallback:YES]) {
        LPLog(@"[media] tắt theo config");
        return;
    }

    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    BOOL a = LPHookMethodTyped(out, @selector(setMaxRecordedDuration:), "v",
                               (IMP)LPMaxDuration, NULL);
    BOOL b = LPHookMethodTyped(out, @selector(setMaxRecordedFileSize:), "v",
                               (IMP)LPMaxFileSize, NULL);
    LPLog(@"[media] AVCaptureMovieFileOutput duration=%d size=%d", a, b);

    Class cap = NSClassFromString(@"AVCaptureSession");
    BOOL c = LPHookMethod(cap, @selector(startRunning), (IMP)LPStartRunning,
                          (IMP *)&gOrigStartRunning);
    BOOL d = LPHookMethod(cap, @selector(stopRunning), (IMP)LPStopRunning,
                          (IMP *)&gOrigStopRunning);
    LPLog(@"[media] AVCaptureSession start=%d stop=%d", c, d);

    // Cờ "đang ghi" — hook trên AVCaptureMovieFileOutput, không phải session.
    Class mfo = NSClassFromString(@"AVCaptureMovieFileOutput");
    BOOL c2 = LPHookMethod(mfo, @selector(startRecordingToOutputFileURL:recordingDelegate:),
                           (IMP)LPStartRecording, (IMP *)&gOrigStartRecording);
    BOOL d2 = LPHookMethod(mfo, @selector(stopRecording), (IMP)LPStopRecording,
                           (IMP *)&gOrigStopRecording);
    LPLog(@"[media] ghi hình start=%d stop=%d", c2, d2);

    Class sess = NSClassFromString(@"AVAudioSession");
    BOOL e = LPHookMethod(sess, @selector(setActive:withOptions:error:),
                          (IMP)LPSetActive, (IMP *)&gOrigSetActive);
    LPLog(@"[media] AVAudioSession.setActive=%d", e);

    Class exp = NSClassFromString(@"AVAssetExportSession");
    BOOL f0 = LPHookMethodTyped(exp, @selector(initWithAsset:presetName:), "@",
                                (IMP)LPExportInit, NULL);
    BOOL f = LPHookMethodTyped(exp, @selector(setTimeRange:), "v",
                               (IMP)LPExportTimeRange, NULL);
    BOOL g = LPHookMethodTyped(exp, @selector(setFileLengthLimit:), "v",
                               (IMP)LPExportFileLengthLimit, NULL);
    BOOL h = LPHookMethodTyped(exp, @selector(exportAsynchronouslyWithCompletionHandler:), "v",
                               (IMP)LPExportAsync, NULL);
    LPLog(@"[media] AVAssetExportSession init=%d range=%d limit=%d export=%d", f0, f, g, h);

    Class picker = NSClassFromString(@"UIImagePickerController");
    BOOL i = LPHookMethodTyped(picker, @selector(setVideoMaximumDuration:), "v",
                               (IMP)LPPickerMaxDuration, NULL);
    LPLog(@"[media] UIImagePickerController duration=%d", i);

    LPLog(@"[media] trần quay %.0fs / %.0fMB · upload %.0fs / %.0fMB · tỉ lệ %@",
          LPEffectiveRecordSeconds(), LPMaxRecordBytes() / 1048576.0,
          LPUploadSeconds(), LPUploadBytes() / 1048576.0,
          [[LPConfig shared] str:@"frameRatioDefault" fallback:@"auto"]);
}
