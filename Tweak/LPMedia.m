#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFAudio/AVFAudio.h>
#import <objc/message.h>
#import <objc/runtime.h>

//
// LPMedia — phá trần quay/chọn video.
//
// ĐÃ BỎ so với bản trước (đây là lỗi làm app chết):
//   - hook -[AVAsset duration]  → chỉ cần đọc duration của video là nổ, và hook
//     getter vốn KHÔNG chặn được giới hạn nào vì app đọc từ Swift property.
//   - hook -[NSFileManager attributesOfItemAtPath:error:] → chạy hàng nghìn lần,
//     và ghi đè NSFileSize làm Locket đọc file lỗi.
//   - hook -[NSURLSession uploadTaskWithRequest:fromData:] → chữ ký block dễ sai,
//     upload ảnh/video nào cũng đi qua đây.
//
// TUYỆT ĐỐI KHÔNG hook getter trả struct (CMTime, CMTimeRange, CGRect...):
// arm64 trả struct >16 byte qua con trỏ ẩn ở x8, không phải tham số thứ 3.
// Khai báo sai chữ ký = ghi vào thanh ghi rác = crash ngay.
//
// GIỚI HẠN THẬT CỦA LOCKET (đọc từ binary 2.68):
//   * Quay: AVCaptureMovieFileOutput.maxRecordedDuration / maxRecordedFileSize  (client)
//   * Chọn từ thư viện: PHPicker (KHÔNG dùng UIImagePickerController) → lọc bằng
//     PHPickerFilter + kiểm tra duration/size sau khi load, không có setter để hook.
//   * Upload: Storage rules + Cloud Function kiểm duration/size  (server, không phá được)
//

static BOOL gMediaHooksInstalled = NO;

static void LPMHook(Class cls, SEL sel, IMP newImp) {
    if (LPHookMethod(cls, sel, newImp, NULL)) {
        LPLog(@"[media] hook %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel));
    } else {
        LPLog(@"[media] bỏ qua %@.%@ (không có)", cls ? NSStringFromClass(cls) : @"nil", NSStringFromSelector(sel));
    }
}

#pragma mark - AVCaptureMovieFileOutput: trần quay

static void LPMovieMaxDurationSet(id self, SEL _cmd, CMTime t) {
    double secs = CMTimeGetSeconds(t);
    if (secs > 0 && !isnan(secs)) LPLog(@"[media] maxRecordedDuration thật = %.1fs -> ép %.0fs", secs, LPVideoSeconds());
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, CMTime))o)(self, _cmd, CMTimeMakeWithSeconds(LPVideoSeconds(), 600));
}

static void LPMovieMaxSizeSet(id self, SEL _cmd, long long size) {
    LPLog(@"[media] maxRecordedFileSize thật = %lld -> ép %.0f", size, LPVideoBytes());
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, long long))o)(self, _cmd, (long long)LPVideoBytes());
}

#pragma mark - UIImagePickerController (Locket 2.68 không dùng, để dành cho bản cũ)

static void LPPickerMaxDurSet(id self, SEL _cmd, double secs) {
    LPLog(@"[media] videoMaximumDuration thật = %.1fs -> ép %.0fs", secs, LPVideoSeconds());
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, double))o)(self, _cmd, LPVideoSeconds());
}

#pragma mark - micro: bật audio session để video có tiếng

// Locket đôi khi tắt audio session khi quay (để không ngắt nhạc đang phát).
// Khi tắt, video xuất ra KHÔNG có tiếng. Bật lại ở chế độ PlayAndRecord.
static void LPEnsureAudioSession(void) {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
              mode:AVAudioSessionModeVideoRecording
           options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                   AVAudioSessionCategoryOptionAllowBluetooth
             error:&err];
    if (err) { LPLog(@"[media] audio session lỗi: %@", err.localizedDescription); return; }
    [s setActive:YES withOptions:0 error:&err];
    if (err) LPLog(@"[media] active audio lỗi: %@", err.localizedDescription);
}

// App gọi setActive:NO khi bắt đầu quay → giữ lại, và đảm bảo category đúng.
static BOOL (*gOrigSetActive)(id, SEL, BOOL, NSUInteger, NSError **);
static BOOL LPSetActive(id self, SEL _cmd, BOOL active, NSUInteger opts, NSError **err) {
    if (!active && [[LPConfig shared] flag:@"keepMicOnRecord" fallback:YES]) {
        LPLog(@"[media] app tắt audio session → giữ lại để video có tiếng");
        LPEnsureAudioSession();
        return YES;
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    return o ? ((BOOL (*)(id, SEL, BOOL, NSUInteger, NSError **))o)(self, _cmd, active, opts, err) : NO;
}

#pragma mark - thêm micro vào session quay nếu app không thêm

// AVCaptureSession của Locket có thể chỉ có video input. Nếu thiếu audio input,
// file quay ra không có tiếng. Thêm audio input ngay khi session bắt đầu.
static void (*gOrigStartRunning)(id, SEL);
static void LPStartRunning(id self, SEL _cmd) {
    @try {
        if (![[LPConfig shared] flag:@"addMicInput" fallback:YES]) {
            if (gOrigStartRunning) gOrigStartRunning(self, _cmd);
            return;
        }
        // Đã có audio input thì thôi.
        BOOL hasAudio = NO;
        NSArray *inputs = ((NSArray *(*)(id, SEL))objc_msgSend)(self, @selector(inputs));
        for (id input in inputs) {
            NSArray *ports = ((NSArray *(*)(id, SEL))objc_msgSend)(input, @selector(ports));
            for (id port in ports) {
                NSString *t = ((id (*)(id, SEL))objc_msgSend)(port, @selector(mediaType));
                if ([t isEqualToString:AVMediaTypeAudio]) { hasAudio = YES; break; }
            }
            if (hasAudio) break;
        }
        if (!hasAudio) {
            AVCaptureDevice *mic = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            if (mic) {
                NSError *e = nil;
                AVCaptureDeviceInput *devIn = [AVCaptureDeviceInput deviceInputWithDevice:mic error:&e];
                if (devIn && ((BOOL (*)(id, SEL, id))objc_msgSend)(self, @selector(canAddInput:), devIn)) {
                    ((BOOL (*)(id, SEL, id))objc_msgSend)(self, @selector(addInput:), devIn);
                    LPLog(@"[media] đã thêm micro vào session quay");
                } else if (e) {
                    LPLog(@"[media] thêm micro lỗi: %@", e.localizedDescription);
                }
            }
        }
        LPEnsureAudioSession();
    } @catch (NSException *e) { LPLog(@"[media] mic lỗi: %@", e); }
    if (gOrigStartRunning) gOrigStartRunning(self, _cmd);
}

#pragma mark - install

void LPInstallMediaHooks(void) {
    if (gMediaHooksInstalled) return;
    gMediaHooksInstalled = YES;

    Class out = NSClassFromString(@"AVCaptureMovieFileOutput");
    LPMHook(out, @selector(setMaxRecordedDuration:), (IMP)LPMovieMaxDurationSet);
    LPMHook(out, @selector(setMaxRecordedFileSize:), (IMP)LPMovieMaxSizeSet);

    // AVAssetExportSession do LPExport.m phụ trách — hook 2 lần sẽ đệ quy.

    Class picker = NSClassFromString(@"UIImagePickerController");
    LPMHook(picker, @selector(setVideoMaximumDuration:), (IMP)LPPickerMaxDurSet);

    Class sess = NSClassFromString(@"AVAudioSession");
    if (LPHookMethod(sess, @selector(setActive:withOptions:error:), (IMP)LPSetActive, (IMP *)&gOrigSetActive)) {
        LPLog(@"[media] hook AVAudioSession.setActive");
    }

    Class capSession = NSClassFromString(@"AVCaptureSession");
    if (LPHookMethod(capSession, @selector(startRunning), (IMP)LPStartRunning, (IMP *)&gOrigStartRunning)) {
        LPLog(@"[media] hook AVCaptureSession.startRunning");
    }

    LPLog(@"[media] trần đặt: %.0fs / %.0fMB", LPVideoSeconds(), LPVideoBytes() / 1048576.0);
}
