//
//  LPExport.m — xuất video theo tỉ lệ khung + nới giới hạn export
//
//  Vì sao cần: Locket chỉ cho đăng video vuông 1:1. Muốn đăng 6:19 / 19:6
//  (dọc / ngang) thì phải tự dựng videoComposition trước khi upload.
//
//  BÀI HỌC TỪ CRASH TRƯỚC: không hook getter trả struct. Ở đây chỉ hook
//  setter (tham số), không có giá trị trả về struct nào.
//

#import "LPCommon.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark - tỉ lệ

// Trả về tỉ lệ rộng/cao mong muốn, hoặc 0 nếu giữ nguyên.
static CGFloat LPRatioValue(NSString *ratio) {
    if (!ratio.length) return 0;
    if ([ratio isEqualToString:@"original"]) return 0;
    NSArray *parts = [ratio componentsSeparatedByString:@":"];
    if (parts.count != 2) return 0;
    CGFloat w = [parts[0] doubleValue];
    CGFloat h = [parts[1] doubleValue];
    if (w <= 0 || h <= 0) return 0;
    return w / h;
}

#pragma mark - xuất video

NSURL *LPExportVideoWithRatio(NSURL *srcURL, NSString *ratio, NSError **outErr) {
    if (!srcURL.isFileURL) {
        if (outErr) *outErr = [NSError errorWithDomain:@"LocketPlus" code:1
                                              userInfo:@{NSLocalizedDescriptionKey: @"không phải file URL"}];
        return nil;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:srcURL
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    if (!asset) return nil;

    AVAssetTrack *vTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!vTrack) {
        if (outErr) *outErr = [NSError errorWithDomain:@"LocketPlus" code:2
                                              userInfo:@{NSLocalizedDescriptionKey: @"video không có track hình"}];
        return nil;
    }

    CGSize natural = vTrack.naturalSize;
    if (natural.width <= 0 || natural.height <= 0) return nil;

    CGFloat target = LPRatioValue(ratio);
    CGFloat outW = natural.width, outH = natural.height;

    if (target > 0) {
        // Giữ cạnh dài của video gốc, mở rộng cạnh còn lại theo tỉ lệ đích.
        // Ví dụ video 1080x1920 (9:16) muốn 6:19 → rộng = 1920 * 6/19 ≈ 606.
        if (target < natural.width / natural.height) {
            outH = natural.height;
            outW = round(natural.height * target);
        } else {
            outW = natural.width;
            outH = round(natural.width / target);
        }
        // Bội số chẵn: nhiều bộ giải mã từ chối kích thước lẻ.
        outW = MAX(2, floor(outW / 2) * 2);
        outH = MAX(2, floor(outH / 2) * 2);
    }

    AVMutableComposition *comp = [AVMutableComposition composition];

    // Hình
    AVMutableCompositionTrack *vComp = [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                         preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError *e = nil;
    if (![vComp insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration)
                        ofTrack:vTrack atTime:kCMTimeZero error:&e]) {
        if (outErr) *outErr = e;
        return nil;
    }
    vComp.preferredTransform = vTrack.preferredTransform;

    // Tiếng: copy nguyên, KHÔNG dùng audioMix → giữ đúng như gốc.
    AVAssetTrack *aTrack = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (aTrack) {
        AVMutableCompositionTrack *aComp = [comp addMutableTrackWithMediaType:AVMediaTypeAudio
                                                             preferredTrackID:kCMPersistentTrackID_Invalid];
        [aComp insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration)
                       ofTrack:aTrack atTime:kCMTimeZero error:NULL];
    }

    AVMutableVideoComposition *vc = [AVMutableVideoComposition videoComposition];
    vc.renderSize = CGSizeMake(outW, outH);
    vc.frameDuration = CMTimeMake(1, 30);

    AVMutableVideoCompositionInstruction *ins = [AVMutableVideoCompositionInstruction videoInstruction];
    ins.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);

    AVMutableVideoCompositionLayerInstruction *layer =
        [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:vComp];

    // Xử lý hướng quay: transform ưu tiên của track có thể xoay 90°.
    CGAffineTransform t = vTrack.preferredTransform;
    CGSize rotated = CGSizeApplyAffineTransform(natural, t);
    rotated = CGSizeMake(fabs(rotated.width), fabs(rotated.height));

    if (target > 0) {
        // Đưa video về gốc toạ độ sau khi xoay, rồi scale vừa khung đích (aspect-fit).
        CGAffineTransform norm = t;
        if (t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0) {
            norm = CGAffineTransformTranslate(t, 0, -natural.width);       // quay phải
        } else if (t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0) {
            norm = CGAffineTransformTranslate(t, -natural.height, 0);      // quay trái
        } else if (t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1) {
            norm = CGAffineTransformTranslate(t, -natural.width, -natural.height);
        }

        CGFloat sx = outW / rotated.width;
        CGFloat sy = outH / rotated.height;
        CGFloat s = MIN(sx, sy);                                          // aspect-fit

        CGFloat dx = (outW - rotated.width * s) / 2.0;
        CGFloat dy = (outH - rotated.height * s) / 2.0;

        CGAffineTransform final = CGAffineTransformConcat(norm, CGAffineTransformMakeScale(s, s));
        final = CGAffineTransformConcat(final, CGAffineTransformMakeTranslation(dx, dy));
        [layer setTransform:final atTime:kCMTimeZero];
    } else {
        [layer setTransform:t atTime:kCMTimeZero];
    }

    ins.layerInstructions = @[layer];
    vc.instructions = @[ins];

    NSString *outName = [NSString stringWithFormat:@"lpexport_%.0f.mp4",
                         [NSDate date].timeIntervalSince1970 * 1000];
    NSURL *outURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:outName]];
    [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];

    // Passthrough không dùng được với videoComposition → luôn dùng preset chất lượng cao.
    AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:comp
                                                               presetName:AVAssetExportPresetHighestQuality];
    if (!ex) {
        ex = [[AVAssetExportSession alloc] initWithAsset:comp
                                              presetName:AVAssetExportPresetMediumQuality];
    }
    if (!ex) return nil;

    ex.outputURL = outURL;
    ex.outputFileType = AVFileTypeMP4;
    ex.shouldOptimizeForNetworkUse = YES;
    if (target > 0) ex.videoComposition = vc;

    // Chờ đồng bộ có timeout: treo app 120s còn hơn treo vĩnh viễn.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [ex exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));

    if (waited != 0) {
        [ex cancelExport];
        if (outErr) *outErr = [NSError errorWithDomain:@"LocketPlus" code:3
                                              userInfo:@{NSLocalizedDescriptionKey: @"export quá 120s"}];
        return nil;
    }
    if (ex.status != AVAssetExportSessionStatusCompleted) {
        if (outErr) *outErr = ex.error ?: [NSError errorWithDomain:@"LocketPlus" code:4
                                                          userInfo:@{NSLocalizedDescriptionKey: @"export thất bại"}];
        return nil;
    }
    LPLog(@"[export] %@ → %@ (%.0fx%.0f)", srcURL.lastPathComponent, outName, outW, outH);
    return outURL;
}

#pragma mark - hook nới giới hạn export

// setFileLengthLimit: nhận long long — tham số, an toàn.
static void (*gOrigFileLimit)(id, SEL, long long);
static void LPSetFileLengthLimit(id self, SEL _cmd, long long limit) {
    long long want = (long long)LPVideoBytes();
    if (limit > 0 && limit < want) {
        LPLog(@"[export] fileLengthLimit %lld → %lld", limit, want);
        limit = want;
    }
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, long long))o)(self, _cmd, limit);
}

// setTimeRange: CMTimeRange là THAM SỐ (không phải giá trị trả về) nên an toàn.
static void (*gOrigTimeRange)(id, SEL, CMTimeRange);
static void LPSetTimeRange(id self, SEL _cmd, CMTimeRange r) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (!o) return;
    if (![[LPConfig shared] flag:@"widenExportRange" fallback:YES]) {
        ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, r);
        return;
    }
    AVAsset *asset = nil;
    @try { asset = [self valueForKey:@"asset"]; } @catch (__unused NSException *e) {}
    if (asset && CMTIME_IS_VALID(asset.duration)) {
        double full = CMTimeGetSeconds(asset.duration);
        double end = CMTimeGetSeconds(CMTimeRangeGetEnd(r));
        // Chỉ nới khi app cắt ngắn hơn thật; không bao giờ kéo dài quá duration.
        if (full > 0 && end > 0 && end < full - 0.05) {
            LPLog(@"[export] range 0→%.2fs của asset %.2fs → mở hết", end, full);
            ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, CMTimeRangeMake(kCMTimeZero, asset.duration));
            return;
        }
    }
    ((void (*)(id, SEL, CMTimeRange))o)(self, _cmd, r);
}

void LPInstallExportHooks(void) {
    Class ex = NSClassFromString(@"AVAssetExportSession");
    if (!ex) { LPLog(@"[export] không có AVAssetExportSession"); return; }
    LPHookMethod(ex, @selector(setFileLengthLimit:), (IMP)LPSetFileLengthLimit, (IMP *)&gOrigFileLimit);
    LPHookMethod(ex, @selector(setTimeRange:), (IMP)LPSetTimeRange, (IMP *)&gOrigTimeRange);
    LPLog(@"[export] hook xong (limit + timeRange)");
}
