//
//  LPNotes.m — bộ "ghi chú genz" cho Locket+
//
//  Thuần tiện ích dữ liệu + UI: KHÔNG hook method nào, không đụng PhotosUI/AVFoundation.
//  Phụ thuộc LPCommon.h: LPLog, LPConfig (+path:), LPShowAlert.
//

#import "LPCommon.h"
#include <stdlib.h>

#pragma mark - preset

static NSArray<NSString *> *gLPNotesPresets;

// Danh sách câu mẫu, chia nhóm theo giọng điệu. Mỗi câu < 60 ký tự, emoji vừa phải.
NSArray<NSString *> *LPNotesPresets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLPNotesPresets = @[
            // --- tự trêu ---
            @"không xinh nhưng được cái tự tin 😌",
            @"mặt mộc, lòng vui, ví hơi mỏng",
            @"tôi không lười, tôi chỉ tiết kiệm năng lượng",
            @"ảnh này chụp lúc tôi cố tỏ ra bình thường",
            @"dáng chưa chuẩn nhưng thần thái có thừa",
            @"hơi mệt nhưng vẫn cố diễn cho đẹp",

            // --- khen nhẹ ---
            @"hôm nay cũng xứng đáng được yêu 🌷",
            @"nhìn lại thấy mình cũng ổn phết",
            @"da này là da thật, không filter đâu",
            @"một chút nắng, một chút xinh",
            @"không cần nổi bật, chỉ cần dễ thương",
            @"hôm nay tôi tự khen mình một câu",

            // --- thả thính hài ---
            @"ai rủ đi ăn là tôi có mặt liền",
            @"tim tôi trống, nhưng ví tôi cũng trống",
            @"crush không rep, nhưng cơm thì rep liền 🍜",
            @"yêu thì chưa, nhưng thương thì có",
            @"đừng thả tim, thả tiền đi",
            @"tôi dễ thương sẵn rồi, không cần thính",

            // --- flex nhẹ ---
            @"không flex gì nhiều, chỉ flex sự bình yên 🌿",
            @"tài sản lớn nhất là giấc ngủ đủ",
            @"hôm nay không giàu, nhưng cũng không vay 💸",
            @"flex nhẹ: hôm nay không có deadline",
            @"đẹp thì không dám nhận, chỉ dám nhận ảnh",
            @"thành tựu hôm nay: dậy đúng giờ",

            // --- đời thường ---
            @"hôm nay sống chậm một chút",
            @"cơm mẹ nấu là best",
            @"đi làm về chỉ muốn nằm",
            @"ngày bình thường nhưng lòng không bình thường",
            @"sáng uống nước, tối ngủ đủ, vậy là giỏi",
            @"không có gì đặc biệt, và thế là đủ",

            // --- học đường ---
            @"sinh viên nghèo nhưng tinh thần giàu",
            @"đi học vì kiến thức, về vì đói 🍚",
            @"thư viện là nhà, ghế là giường",
            @"học không giỏi nhưng chăm đi học",
            @"bài tập về nhà đang nhìn tôi",
            @"năm cuối rồi, cố lên",

            // --- deadline ---
            @"deadline là bạn thân của tôi ☕️",
            @"nước đến chân mới nhảy, mà nhảy cũng qua",
            @"tôi sống theo deadline, deadline sống theo tôi",
            @"cà phê là nhiên liệu, deadline là động lực",
            @"hôm nay cũng là một ngày chạy deadline",
            @"xong bài rồi, xin phép được thở 😮‍💨",

            // --- cà phê ---
            @"một ly cà phê cứu cả một buổi sáng ☕️",
            @"không cà phê thì không nói chuyện",
            @"quán quen, góc quen, người quen",
            @"cà phê đắng, nhưng đời thì ngọt",
            @"ngồi cà phê một mình cũng là một cách nghỉ",
            @"sáng nay tôi chọn cà phê thay vì càu nhàu",

            // --- mèo ---
            @"mèo nhà tôi là chủ, tôi là người hầu 🐾",
            @"vuốt mèo xong thấy đời dễ chịu hẳn",
            @"mèo ngủ, tôi cũng muốn ngủ",
            @"ảnh có mèo là ảnh có hồn 🐱",
            @"mèo không thương tôi, nhưng tôi vẫn thương mèo",
            @"hôm nay mèo cho tôi chụp chung, may ghê",

            // --- mưa ---
            @"mưa rồi, ở nhà thôi 🌧",
            @"mưa Sài Gòn, lòng cũng hơi ướt",
            @"nghe mưa rơi cũng là một loại nhạc",
            @"mưa thì mặc mưa, tôi vẫn đi cà phê",
            @"trời mưa, deadline vẫn không mưa",
            @"một chiếc ảnh cho ngày mưa"
        ];
    });
    return gLPNotesPresets;
}

NSString *LPNotesRandom(void) {
    NSArray<NSString *> *all = LPNotesPresets();
    if (all.count == 0) return @"";
    return all[arc4random_uniform((uint32_t)all.count)];
}

#pragma mark - note của người dùng

static NSString *const kLPNotesKey = @"userNotes";
static const NSUInteger kLPNotesMax = 200;      // trần số note lưu được
static const NSUInteger kLPNotesMaxLen = 200;   // trần độ dài 1 note

// Khoá đơn giản cho add/remove (UI có thể gọi từ nhiều chỗ).
static id LPNotesLock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

// Chuẩn hoá: bỏ khoảng trắng đầu/cuối, gộp khoảng trắng đôi. Trả nil nếu rỗng.
static NSString *LPNotesNormalize(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([t rangeOfString:@"  "].location != NSNotFound) {
        t = [t stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return t.length ? t : nil;
}

static BOOL LPNotesContains(NSArray<NSString *> *arr, NSString *note) {
    for (NSString *s in arr) {
        if ([s caseInsensitiveCompare:note] == NSOrderedSame) return YES;
    }
    return NO;
}

// Đọc plist; luôn trả mảng mutable, đã lọc kiểu + cắt về giới hạn.
static NSMutableArray<NSString *> *LPNotesLoad(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[LPConfig path:@"notes.plist"]];
    id raw = [d isKindOfClass:[NSDictionary class]] ? d[kLPNotesKey] : nil;
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id o in (NSArray *)raw) {
            if (![o isKindOfClass:[NSString class]]) continue;
            NSString *n = LPNotesNormalize(o);
            if (n && !LPNotesContains(out, n)) [out addObject:n];
        }
    }
    if (out.count > kLPNotesMax) {
        [out removeObjectsInRange:NSMakeRange(kLPNotesMax, out.count - kLPNotesMax)];
    }
    return out;
}

static void LPNotesSave(NSArray<NSString *> *notes) {
    NSArray *trimmed = notes ?: @[];
    if (trimmed.count > kLPNotesMax) {
        trimmed = [trimmed subarrayWithRange:NSMakeRange(0, kLPNotesMax)];
    }
    NSDictionary *d = @{ kLPNotesKey: trimmed };
    NSString *p = [LPConfig path:@"notes.plist"];
    if (![d writeToFile:p atomically:YES]) {
        LPLog(@"[notes] ghi plist thất bại: %@", p);
    }
}

NSArray<NSString *> *LPNotesUserNotes(void) {
    @synchronized (LPNotesLock()) {
        return [LPNotesLoad() copy];
    }
}

void LPNotesAdd(NSString *note) {
    NSString *n = LPNotesNormalize(note);
    if (!n) return;
    if (n.length > kLPNotesMaxLen) n = [n substringToIndex:kLPNotesMaxLen];

    @synchronized (LPNotesLock()) {
        NSMutableArray<NSString *> *arr = LPNotesLoad();
        if (LPNotesContains(arr, n)) {
            LPLog(@"[notes] đã có, bỏ qua: %@", n);
            return;
        }
        [arr insertObject:n atIndex:0];   // note mới lên đầu
        if (arr.count > kLPNotesMax) {
            [arr removeObjectsInRange:NSMakeRange(kLPNotesMax, arr.count - kLPNotesMax)];
        }
        LPNotesSave(arr);
        LPLog(@"[notes] đã thêm, tổng %lu", (unsigned long)arr.count);
    }
}

void LPNotesRemove(NSString *note) {
    NSString *n = LPNotesNormalize(note);
    if (!n) return;

    @synchronized (LPNotesLock()) {
        NSMutableArray<NSString *> *arr = LPNotesLoad();
        NSString *found = nil;
        for (NSString *s in arr) {
            if ([s caseInsensitiveCompare:n] == NSOrderedSame) { found = s; break; }
        }
        if (!found) return;
        [arr removeObject:found];
        LPNotesSave(arr);
        LPLog(@"[notes] đã xoá, còn %lu", (unsigned long)arr.count);
    }
}

#pragma mark - tìm view controller trên cùng

// Duyệt scene → window key → root → các VC đang present. Trả nil nếu chưa có UI.
static UIViewController *LPNotesTopViewController(void) {
    UIWindow *keyWin = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.isKeyWindow) { keyWin = w; break; }
        }
        if (keyWin) break;
    }
    if (!keyWin) {
        // Fallback: scene chưa kịp active thì lấy window đầu tiên.
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            keyWin = ((UIWindowScene *)sc).windows.firstObject;
            if (keyWin) break;
        }
    }
    UIViewController *vc = keyWin.rootViewController;
    if (!vc) return nil;

    // Đi xuống container (nav/tab) rồi lên các VC đang present.
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *t = ((UINavigationController *)vc).topViewController;
        if (t) vc = t;
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *t = ((UITabBarController *)vc).selectedViewController;
        if (t) vc = t;
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// Action sheet vừa bị đóng; chờ một nhịp rồi mới present cái khác để không bị nuốt.
static void LPNotesAfterSheet(UIAlertController *sheet, dispatch_block_t block) {
    if (!block) return;
    if (sheet.presentingViewController) {
        [sheet dismissViewControllerAnimated:YES completion:nil];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

#pragma mark - hành động

// Copy vào clipboard rồi báo cho người dùng biết.
static void LPNotesCopy(NSString *note) {
    if (note.length == 0) return;
    UIPasteboard.generalPasteboard.string = note;
    LPShowAlert(@"Đã copy", note);
}

// Alert nhập note tự viết.
static void LPNotesShowCompose(void) {
    UIViewController *vc = LPNotesTopViewController();
    if (!vc) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"✏️ Ghi chú của bạn"
                                                              message:@"Viết caption cho tấm ảnh này"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"ví dụ: hôm nay cũng xứng đáng được yêu";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];

    __weak UIAlertController *weakAlert = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        NSString *text = weakAlert.textFields.firstObject.text;
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) return;
        LPNotesAdd(trimmed);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LPShowAlert(@"Đã lưu ghi chú", trimmed);
        });
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];

    [vc presentViewController:a animated:YES completion:nil];
}

// Trộn ngẫu nhiên (Fisher–Yates) rồi lấy tối đa n phần tử.
static NSArray<NSString *> *LPNotesSample(NSArray<NSString *> *src, NSUInteger n) {
    if (src.count == 0 || n == 0) return @[];
    NSMutableArray<NSString *> *arr = [src mutableCopy];
    for (NSUInteger i = arr.count; i > 1; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)i);
        [arr exchangeObjectAtIndex:(i - 1) withObjectAtIndex:j];
    }
    if (arr.count > n) [arr removeObjectsInRange:NSMakeRange(n, arr.count - n)];
    return arr;
}

#pragma mark - picker

void LPNotesShowPicker(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LPNotesShowPicker(); });
        return;
    }

    UIViewController *vc = LPNotesTopViewController();
    if (!vc) {
        LPLog(@"[notes] không tìm được view controller, bỏ qua picker");
        return;
    }

    NSArray<NSString *> *presets = LPNotesSample(LPNotesPresets(), 12);   // tối đa 12 preset
    NSArray<NSString *> *mine = LPNotesUserNotes();
    if (mine.count > 8) mine = [mine subarrayWithRange:NSMakeRange(0, 8)]; // tối đa 8 note

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Ghi chú genz"
                                                                   message:@"Chọn một câu để copy"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIAlertController *weakSheet = sheet;

    // 1) preset ngẫu nhiên
    for (NSString *note in presets) {
        [sheet addAction:[UIAlertAction actionWithTitle:note style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            NSString *text = note;
            LPNotesAfterSheet(weakSheet, ^{ LPNotesCopy(text); });
        }]];
    }

    // 2) note người dùng tự viết
    for (NSString *note in mine) {
        NSString *title = [NSString stringWithFormat:@"📝 %@", note];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
            NSString *text = note;
            LPNotesAfterSheet(weakSheet, ^{ LPNotesCopy(text); });
        }]];
    }

    // 3) tự viết
    [sheet addAction:[UIAlertAction actionWithTitle:@"✏️ Tự viết" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) {
        LPNotesAfterSheet(weakSheet, ^{ LPNotesShowCompose(); });
    }]];

    // 4) huỷ
    [sheet addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];

    // iPad: action sheet cần điểm neo, thiếu sẽ crash.
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = vc.view;
        sheet.popoverPresentationController.sourceRect =
            CGRectMake(vc.view.bounds.size.width / 2.0, vc.view.bounds.size.height / 2.0, 1.0, 1.0);
    }

    [vc presentViewController:sheet animated:YES completion:nil];
    LPLog(@"[notes] picker: %lu preset + %lu note", (unsigned long)presets.count, (unsigned long)mine.count);
}
