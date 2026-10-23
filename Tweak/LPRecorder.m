// ============================================================================
//  LPRecorder.m — can thiệp Camera.Recorder (class Swift của Locket)
//
//  BẰNG CHỨNG từ binary Locket 2.69 (Payload/Locket.app/Locket, 53.4 MB):
//
//  • Danh sách entitlement Gold (__cstring 0x2818c80):
//      cameraFilterSheet cameraTheme customWidgetFrames locketViews
//      longCaptions longerVideo prioritySupport profileBadge
//      removeAds streakRecovery unlimitedFriends
//    → "longerVideo" là thứ quyết định 15s hay 60s.
//
//  • Field của class _TtC6Camera8Recorder (reflection metadata 0x29eb030):
//      _goldMaxDuration      ← thời lượng khi có Gold
//      _longerVideosEnabled  ← cờ bật
//      _microphoneEnabled    ← mic
//      _microphoneConfigured
//      _microphoneAuthorizationStatus
//      _microphoneButtonEnabled
//      _audioClient  audioFrameContinuation   ← pipeline CÓ audio
//      _recording  _qualityMbps  _otherMusicPlaying
//
//  • Remote Config key (cstring 0x27a9680):
//      camera_microphone_enabled
//
//  • Enum lỗi của Recorder (reflstr 0x29ee69e):
//      recording ended failedToStart fileWriteFailed cantAddInput
//      cancelled invalidInterval notReadyForMoreData noImage
//      noAudio noFramesRecorded recordingEnded
//
//  CHIẾN LƯỢC — 3 tầng, tầng nào ăn thì dùng:
//    1. KVC  : setValue:forKey:@"_goldMaxDuration" …  (nếu field @objc dynamic)
//    2. IVAR : object_setIvar nếu tìm được ivar cùng tên
//    3. LOG  : nếu cả hai trượt, log rõ để biết phải đi đường khác
//
//  MỌI thao tác đều bọc @try. KVC lên key không tồn tại sẽ ném
//  NSUnknownKeyException và GIẾT APP nếu không bắt — đây là rủi ro chính.
// ============================================================================

#import "LPCommon.h"
#import <objc/runtime.h>
#import <objc/message.h>

static const char *kRecorderClass = "_TtC6Camera8Recorder";

static NSMutableArray *gRecorders;      // các instance đã thấy
static NSLock *gRecLock;
static BOOL gApplied = NO;

#define REC(fmt, ...) LPLog(@"[rec] " fmt, ##__VA_ARGS__)

#pragma mark - ghi giá trị vào một instance

// Trả về: 0 = không có field, 1 = KVC OK, 2 = ivar OK
static int LPSetNumber(id obj, NSString *key, double value, const char *ivarName) {
    if (!obj || !key) return 0;

    // --- 1. KVC ---
    @try {
        if ([obj respondsToSelector:@selector(setValue:forKey:)]) {
            // Đọc trước: nếu getter không tồn tại, KVC sẽ ném ngay ở đây
            // thay vì ghi thành công một cách vô nghĩa.
            id cur = [obj valueForKey:key];
            (void)cur;
            [obj setValue:@(value) forKey:key];
            return 1;
        }
    } @catch (NSException *e) {
        // Không phải @objc dynamic → thử ivar.
    }

    // --- 2. IVAR ---
    if (ivarName) {
        @try {
            Class c = object_getClass(obj);
            for (Class k = c; k; k = class_getSuperclass(k)) {
                Ivar iv = class_getInstanceVariable(k, ivarName);
                if (!iv) continue;
                const char *enc = ivar_getTypeEncoding(iv);
                if (!enc) break;

                ptrdiff_t off = ivar_getOffset(iv);
                uint8_t *base = (uint8_t *)(__bridge void *)obj;

                if (enc[0] == 'd') {                     // double
                    *(double *)(base + off) = value;
                    return 2;
                }
                if (enc[0] == 'f') {                     // float
                    *(float *)(base + off) = (float)value;
                    return 2;
                }
                if (enc[0] == 'B' || enc[0] == 'c') {    // Bool / char
                    *(uint8_t *)(base + off) = (value != 0);
                    return 2;
                }
                if (enc[0] == 'q' || enc[0] == 'Q') {
                    *(int64_t *)(base + off) = (int64_t)value;
                    return 2;
                }
                if (enc[0] == 'i' || enc[0] == 'I') {
                    *(int32_t *)(base + off) = (int32_t)value;
                    return 2;
                }
                break;
            }
        } @catch (__unused NSException *e) {}
    }
    return 0;
}

#pragma mark - áp cấu hình lên một Recorder

static void LPApplyToRecorder(id rec) {
    if (!rec) return;

    double secs = LPMaxRecordSeconds();
    BOOL wantMic = [[LPConfig shared] flag:@"addMicInput" fallback:NO];

    int a = LPSetNumber(rec, @"_goldMaxDuration", secs, "_goldMaxDuration");
    int b = LPSetNumber(rec, @"_longerVideosEnabled", 1, "_longerVideosEnabled");
    int c = wantMic ? LPSetNumber(rec, @"_microphoneEnabled", 1, "_microphoneEnabled") : 0;
    int d = wantMic ? LPSetNumber(rec, @"_microphoneConfigured", 1, "_microphoneConfigured") : 0;

    // Đọc lại để chứng minh nó ăn.
    double back = -1;
    @try {
        id v = [rec valueForKey:@"_goldMaxDuration"];
        if ([v respondsToSelector:@selector(doubleValue)]) back = [v doubleValue];
    } @catch (__unused NSException *e) {}

    REC("goldMaxDuration=%d longerVideos=%d mic=%d micConf=%d · đọc lại %.0fs",
        a, b, c, d, back);

    if (a == 0 && b == 0) {
        REC("TRƯỢT cả KVC và ivar — field không @objc dynamic, cần cách khác");
    }
}

#pragma mark - bắt instance Recorder

// Class là ObjC-visible (có trong __objc_classname) nên nó có -init.
// Hook init để lấy instance ngay khi Locket tạo.
static id (*gOrigInit)(id, SEL);

static id LPRecorderInit(id self, SEL _cmd) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return nil;
    id r = ((id (*)(id, SEL))o)(self, _cmd);

    if (r) {
        [gRecLock lock];
        if (!gRecorders) gRecorders = [NSMutableArray array];
        // Giữ yếu để không giữ Recorder sống ngoài ý muốn.
        for (NSValue *v in gRecorders) {
            if (v.nonretainedObjectValue == r) { [gRecLock unlock]; return r; }
        }
        [gRecorders addObject:[NSValue valueWithNonretainedObject:r]];
        [gRecLock unlock];

        REC("tạo Recorder %p", r);
        @try { LPApplyToRecorder(r); } @catch (__unused NSException *e) {}
    }
    return r;
}

#pragma mark - áp lại sau khi Gold về

// Camera được tạo lúc app khởi động, TRƯỚC khi RevenueCat trả CustomerInfo.
// Nên _longerVideosEnabled lúc đó = false. Phải áp lại sau khi Gold có.
void LPRecorderReapply(void) {
    NSArray *snapshot;
    [gRecLock lock];
    snapshot = [gRecorders copy];
    [gRecLock unlock];

    if (!snapshot.count) { REC("chưa thấy Recorder nào"); return; }
    for (NSValue *v in snapshot) {
        id rec = v.nonretainedObjectValue;
        if (!rec) continue;
        @try { LPApplyToRecorder(rec); } @catch (__unused NSException *e) {}
    }
    gApplied = YES;
}

#pragma mark - install

void LPInstallRecorder(void) {
    if (![[LPConfig shared] flag:@"recorderPatch" fallback:YES]) return;

    Class rec = NSClassFromString([NSString stringWithUTF8String:kRecorderClass]);
    if (!rec) {
        REC("không thấy %s — chờ", kRecorderClass);
        for (int i = 1; i <= 8; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                Class c = NSClassFromString([NSString stringWithUTF8String:kRecorderClass]);
                if (!c) return;
                BOOL ok = LPHookMethod(c, @selector(init), (IMP)LPRecorderInit,
                                       (IMP *)&gOrigInit);
                REC("hook Recorder.init (muộn) = %d", ok);
            });
        }
        return;
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{ gRecLock = [NSLock new]; });

    BOOL ok = LPHookMethod(rec, @selector(init), (IMP)LPRecorderInit, (IMP *)&gOrigInit);
    REC("hook %s init = %d", kRecorderClass, ok);

    // Áp lại vài lần: lúc app lên, lúc Gold về, lúc camera mở.
    for (int i = 0; i < 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((2 + i * 3) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ LPRecorderReapply(); });
    }
}
