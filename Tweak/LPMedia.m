// ============================================================================
//  LPMedia.m — trần quay 600s / 500MB + nén khi cần
//
//  ĐÃ ĐỌC LẠI ASSEMBLY của MHVideoPipeline.dylib. Bản trước tôi ghi SAI 3 chỗ
//  trong comment và trong README — sửa lại cho đúng sự thật:
//
//  SỰ THẬT về MHVideoPipeline (bằng chứng ở từng địa chỉ):
//    • Nó hook -[AVAssetExportSession initWithAsset:presetName:]  (_ExportInit @0x8420)
//      KHÔNG hook setMaxRecordedDuration/FileSize → nó KHÔNG đụng trần quay.
//    • Preset ladder HẠ CẤP, thứ tự thật: 1280x720 TRƯỚC, rồi 1920x1080,
//      không có cả hai thì giữ preset gốc. (0x8558, 0x8590, 0x85c0)
//    • _Configure (@0x8d88) set:
//          setFileLengthLimit: 0x600000 = 6 MB     (KHÔNG phải 500MB)
//          setShouldOptimizeForNetworkUse: YES
//          setCanPerformMultiplePassesOverSourceMediaData: NO  (KHÔNG phải YES)
//    • Hằng 0x17c88 = 600 KHÔNG phải "600 giây" — đó là timescale của
//      kCMTimeZero (value=0, timescale=600, flags=1). Nó dùng cho
//      setTransform:atTime: trong _FitComposition, không liên quan thời lượng.
//
//  => Dylib mẫu là tweak NÉN video cho vừa giới hạn upload, không phải tweak
//     nâng giới hạn. Đó mới là cách video dài thực sự upload được.
//
//  LocketPlus làm CẢ HAI, tách bằng config:
//    • Mặc định: nâng trần quay lên 600s/500MB (yêu cầu của người dùng).
//    • compressForUpload=true: theo đúng chiến lược dylib mẫu — hạ preset +
//      ép fileLengthLimit về uploadTargetBytes (mặc định 6MB).
//
//  TUYỆT ĐỐI KHÔNG hook getter trả struct (CMTime, CMTimeRange, CGRect...).
//  Trên arm64 struct > 16 byte trả qua con trỏ ẩn ở x8 — khai báo sai chữ ký
//  là ghi vào thanh ghi rác → crash (đúng lỗi v1.5/v1.6).
//  Chỉ hook SETTER nhận struct làm THAM SỐ — tham số thì truyền bình thường.
// ============================================================================

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <objc/message.h>

static BOOL gMediaInstalled = NO;

#pragma mark - AVCaptureMovieFileOutput

static void LPMaxDuration(id self, SEL _cmd, CMTime t) {
    double want = LPVideoSeconds();
    double real = CMTimeGetSeconds(t);
    if (isfinite(real) && real > 0 && real < want) {
        LPLog(@"[media] maxRecordedDuration %.0fs → %.0fs", real, want);
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    CMTime v = CMTimeMakeWithSeconds(want, 600);
    ((void (*)(id, SEL, CMTime))o)(self, _cmd, v);
}

static void LPMaxFileSize(id self, SEL _cmd, long long size) {
    long long want = (long long)LPVideoBytes();
    if (size > 0 && size < want) {
        LPLog(@"[media] maxRecordedFileSize %lld → %lld", size, want);
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, long long))o)(self, _cmd, want);
}

#pragma mark - preset ladder (bám sát MHVideoPipeline._ExportInit)

// ĐỌC LẠI ASSEMBLY CHO ĐÚNG — bản trước tôi ghi sai trong README:
//
//   _ExportInit được hook vào -[AVAssetExportSession initWithAsset:presetName:].
//   Nó gọi +exportPresetsCompatibleWithAsset: rồi kiểm theo ĐÚNG thứ tự này:
//       1. containsObject:@"AVAssetExportPreset1280x720"   → dùng 1280x720
//       2. containsObject:@"AVAssetExportPreset1920x1080"  → dùng 1920x1080
//       3. không có cả hai                                  → giữ preset gốc
//
//   Tức đây là ladder HẠ CẤP (ưu tiên 720p trước), để file nhỏ.
//   KHÔNG phải "HighestQuality → 1080p → 720p" như tôi viết nhầm.
//
//   _Configure sau đó set:
//       setFileLengthLimit: 0x600000  = 6 MB   (KHÔNG phải 500MB)
//       setShouldOptimizeForNetworkUse: YES
//       setCanPerformMultiplePassesOverSourceMediaData: NO  (KHÔNG phải YES)
//
//   => Dylib mẫu KHÔNG nâng giới hạn. Nó NÉN video cho vừa giới hạn upload
//      của server. Đó mới là cách video dài thực sự upload được.
//   => Nó cũng KHÔNG hề hook setMaxRecordedDuration — trần quay là việc của ta.
//
// Chiến lược của LocketPlus: mặc định GIỮ 500MB (đúng yêu cầu người dùng),
// chỉ nén khi bật "compressForUpload" (dùng khi upload bị server từ chối).

static void LPConfigureExportSession(id session);

static NSArray<NSString *> *LPExportPresetLadder(void) {
    id v = [[LPConfig shared] obj:@"exportPresetLadder"];
    if ([v isKindOfClass:[NSArray class]] && [v count]) return v;
    // Mặc định = đúng thứ tự của dylib mẫu.
    return @[@"AVAssetExportPreset1280x720",
             @"AVAssetExportPreset1920x1080"];
}

// Chọn preset: nếu compressForUpload thì lấy preset đầu tiên tương thích,
// ngược lại giữ nguyên preset app yêu cầu.
static NSString *LPChoosePreset(id asset, NSString *requested) {
    if (![[LPConfig shared] flag:@"compressForUpload" fallback:NO]) return requested;
    if (!asset) return requested;

    @try {
        Class exp = NSClassFromString(@"AVAssetExportSession");
        if (!exp) return requested;
        SEL sel = NSSelectorFromString(@"exportPresetsCompatibleWithAsset:");
        if (![exp respondsToSelector:sel]) return requested;

        NSArray *compatible = ((id (*)(id, SEL, id))objc_msgSend)((id)exp, sel, asset);
        if (![compatible isKindOfClass:[NSArray class]] || !compatible.count) return requested;

        for (NSString *p in LPExportPresetLadder()) {
            if ([compatible containsObject:p]) {
                if (![p isEqualToString:requested]) {
                    LPLog(@"[media] preset %@ → %@ (nén để vừa upload)", requested, p);
                }
                return p;
            }
        }
    } @catch (NSException *e) { LPLog(@"[media] chọn preset lỗi: %@", e.reason); }
    return requested;
}

static id (*gOrigExportInit)(id, SEL, id, NSString *);
static id LPExportInit(id self, SEL _cmd, id asset, NSString *preset) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    NSString *use = LPChoosePreset(asset, preset);
    id session = ((id (*)(id, SEL, id, NSString *))o)(self, _cmd, asset, use);
    // _Configure của dylib mẫu chạy ngay sau khi tạo session.
    if (session) {
        @try { LPConfigureExportSession(session); }
        @catch (__unused NSException *e) {}
    }
    return session;
}

// Tương đương _Configure của MHVideoPipeline, nhưng đọc config.
static void LPConfigureExportSession(id session) {
    if (!session) return;

    if ([session respondsToSelector:@selector(setFileLengthLimit:)]) {
        long long limit = [[LPConfig shared] flag:@"compressForUpload" fallback:NO]
            ? (long long)[[LPConfig shared] dbl:@"uploadTargetBytes" fallback:6.0 * 1024 * 1024]
            : (long long)LPVideoBytes();
        ((void (*)(id, SEL, long long))objc_msgSend)(
            session, @selector(setFileLengthLimit:), limit);
    }
    if ([session respondsToSelector:@selector(setShouldOptimizeForNetworkUse:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            session, @selector(setShouldOptimizeForNetworkUse:), YES);
    }
    if ([session respondsToSelector:@selector(setCanPerformMultiplePassesOverSourceMediaData:)]) {
        // Dylib mẫu set NO. Multi-pass cần thêm dung lượng tạm và hay fail
        // trên video dài → theo mẫu, chỉ bật khi người dùng yêu cầu.
        BOOL multi = [[LPConfig shared] flag:@"exportMultiPass" fallback:NO];
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            session, @selector(setCanPerformMultiplePassesOverSourceMediaData:), multi);
    }
}

#pragma mark - AVAssetExportSession

// Locket tự cắt video trước khi upload: setTimeRange + setFileLengthLimit.
//
// CẨN THẬN: setTimeRange cũng là API người dùng dùng để CẮT video (trim).
// Tự nới range = phá ý định của người dùng (cắt 15s thành 60s).
// Vì vậy mặc định CHỈ GHI LOG. Muốn nới thì bật "expandExportRange" = true
// trong config.plist và tự chịu rủi ro đó.
//
// CMTimeRange là struct 48 byte → arm64 truyền gián tiếp qua con trỏ.
// Khai báo ĐÚNG kiểu struct là compiler tự lo ABI; khai báo sai (void*) là crash.
static void LPExportTimeRange(id self, SEL _cmd, CMTimeRange r) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    CMTimeRange use = r;
    @try {
        double d = CMTimeGetSeconds(r.duration);
        if (isfinite(d) && d > 0) {
            LPLog(@"[media] export timeRange %.1fs (start %.1fs)", d, CMTimeGetSeconds(r.start));
        }
        if ([[LPConfig shared] flag:@"expandExportRange" fallback:NO] &&
            isfinite(d) && d > 0 && d < LPVideoSeconds()) {
            id asset = ((id (*)(id, SEL))objc_msgSend)(self, @selector(asset));
            if (asset) {
                CMTime ad = ((CMTime (*)(id, SEL))objc_msgSend)(asset, @selector(duration));
                double assetSecs = CMTimeGetSeconds(ad);
                if (isfinite(assetSecs) && assetSecs > d + 0.05) {
                    double want = MIN(assetSecs, LPVideoSeconds());
                    use = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(want, 600));
                    LPLog(@"[media] nới timeRange %.1fs → %.1fs", d, want);
                }
            }
        }
    } @catch (__unused NSException *e) {}

    ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, use);
}

static void LPExportFileLengthLimit(id self, SEL _cmd, long long limit) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;

    // Chế độ nén để upload: KHÔNG nới, ngược lại còn hạ xuống mục tiêu.
    // Nếu nới ở đây thì LPConfigureExportSession vừa set 6MB sẽ bị đẩy lại
    // 500MB → mất tác dụng nén.
    if ([[LPConfig shared] flag:@"compressForUpload" fallback:NO]) {
        long long target = (long long)[[LPConfig shared] dbl:@"uploadTargetBytes"
                                                    fallback:6.0 * 1024 * 1024];
        long long use = (limit > 0 && limit < target) ? limit : target;
        if (use != limit) LPLog(@"[media] fileLengthLimit %lld → %lld (nén)", limit, use);
        ((void (*)(id, SEL, long long))o)(self, _cmd, use);
        return;
    }

    long long want = (long long)LPVideoBytes();
    long long use = (limit > 0 && limit < want) ? want : limit;
    if (use != limit) LPLog(@"[media] fileLengthLimit %lld → %lld", limit, use);
    ((void (*)(id, SEL, long long))o)(self, _cmd, use);
}

#pragma mark - UIImagePickerController (bản Locket cũ)

static void LPPickerMaxDuration(id self, SEL _cmd, double secs) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    ((void (*)(id, SEL, double))o)(self, _cmd, LPVideoSeconds());
}

#pragma mark - micro

static void LPEnsureAudioSession(void) {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
              mode:AVAudioSessionModeVideoRecording
           options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                   AVAudioSessionCategoryOptionAllowBluetooth
             error:&err];
    if (err) { LPLog(@"[media] audio category lỗi: %@", err.localizedDescription); return; }
    [s setActive:YES withOptions:0 error:&err];
    if (err) LPLog(@"[media] audio active lỗi: %@", err.localizedDescription);
}

static BOOL (*gOrigSetActive)(id, SEL, BOOL, NSUInteger, NSError **);
static BOOL LPSetActive(id self, SEL _cmd, BOOL active, NSUInteger opts, NSError **err) {
    if (!active && [[LPConfig shared] flag:@"keepMicOnRecord" fallback:YES]) {
        LPEnsureAudioSession();
        return YES;
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    return o ? ((BOOL (*)(id, SEL, BOOL, NSUInteger, NSError **))o)(self, _cmd, active, opts, err)
             : NO;
}

static void (*gOrigStartRunning)(id, SEL);
static void LPStartRunning(id self, SEL _cmd) {
    @try {
        if ([[LPConfig shared] flag:@"addMicInput" fallback:YES]) {
            BOOL hasAudio = NO;
            NSArray *inputs = ((NSArray *(*)(id, SEL))objc_msgSend)(self, @selector(inputs));
            if ([inputs isKindOfClass:[NSArray class]]) {
                for (id input in inputs) {
                    NSArray *ports = ((NSArray *(*)(id, SEL))objc_msgSend)(input, @selector(ports));
                    if (![ports isKindOfClass:[NSArray class]]) continue;
                    for (id port in ports) {
                        NSString *t = ((id (*)(id, SEL))objc_msgSend)(port, @selector(mediaType));
                        if ([t isEqualToString:AVMediaTypeAudio]) { hasAudio = YES; break; }
                    }
                    if (hasAudio) break;
                }
            }
            if (!hasAudio) {
                AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
                if (mic) {
                    NSError *e = nil;
                    AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:mic error:&e];
                    if (in && ((BOOL (*)(id, SEL, id))objc_msgSend)(self, @selector(canAddInput:), in)) {
                        ((BOOL (*)(id, SEL, id))objc_msgSend)(self, @selector(addInput:), in);
                        LPLog(@"[media] thêm micro vào session quay");
                    }
                }
            }
            LPEnsureAudioSession();
        }
    } @catch (NSException *e) { LPLog(@"[media] mic: %@", e.reason); }
    if (gOrigStartRunning) gOrigStartRunning(self, _cmd);
}

#pragma mark - install

void LPInstallMediaHooks(void) {
    if (gMediaInstalled) return;
    gMediaInstalled = YES;

    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    BOOL a = LPHookMethodTyped(out, @selector(setMaxRecordedDuration:), "v",
                               (IMP)LPMaxDuration, NULL);
    BOOL b = LPHookMethodTyped(out, @selector(setMaxRecordedFileSize:), "v",
                               (IMP)LPMaxFileSize, NULL);
    LPLog(@"[media] AVCaptureMovieFileOutput duration=%d size=%d", a, b);

    Class exp = NSClassFromString(@"AVAssetExportSession");
    BOOL c = LPHookMethodTyped(exp, @selector(setFileLengthLimit:), "v",
                               (IMP)LPExportFileLengthLimit, NULL);
    BOOL d = LPHookMethodTyped(exp, @selector(setTimeRange:), "v",
                               (IMP)LPExportTimeRange, NULL);
    BOOL e = LPHookMethodTyped(exp, @selector(initWithAsset:presetName:), "@",
                               (IMP)LPExportInit, (IMP *)&gOrigExportInit);
    LPLog(@"[media] AVAssetExportSession limit=%d range=%d init=%d", c, d, e);

    Class picker = NSClassFromString(@"UIImagePickerController");
    BOOL f = LPHookMethodTyped(picker, @selector(setVideoMaximumDuration:), "v",
                               (IMP)LPPickerMaxDuration, NULL);
    LPLog(@"[media] UIImagePickerController duration=%d", f);

    Class sess = NSClassFromString(@"AVAudioSession");
    if (LPHookMethod(sess, @selector(setActive:withOptions:error:),
                     (IMP)LPSetActive, (IMP *)&gOrigSetActive)) {
        LPLog(@"[media] AVAudioSession.setActive");
    }

    Class cap = NSClassFromString(@"AVCaptureSession");
    if (LPHookMethod(cap, @selector(startRunning), (IMP)LPStartRunning,
                     (IMP *)&gOrigStartRunning)) {
        LPLog(@"[media] AVCaptureSession.startRunning");
    }

    LPLog(@"[media] trần: %.0fs / %.0fMB", LPVideoSeconds(), LPVideoBytes() / 1048576.0);
}
