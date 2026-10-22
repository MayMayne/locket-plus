#import "LPCommon.h"
#import <objc/runtime.h>

//
// LPPatch — vá theo cấu hình cho hàm của app mà ta chưa biết tên.
// Tìm class/selector bằng Runtime Explorer rồi thêm vào config.plist, không cần build lại.
//
// Thêm vào config.plist:
//   patches = [
//     { class = "SomeViewController"; selector = "maxVideoDuration"; mode = "clamp"; value = 600 }
//     { class = "SomeUploader";       selector = "isVideoTooLong:"; mode = "false" }
//     { class = "SomeUploader";       selector = "maxVideoBytes";   mode = "return"; value = 524288000 }
//   ]
// mode: clamp (chỉ hạ giá trị trả về) | return (luôn trả giá trị) | true | false
//
// SỬA QUAN TRỌNG: trước đây khi class chưa tồn tại (Swift class nạp muộn), patch
// bị đánh dấu "đã xử lý" và KHÔNG BAO GIỜ được áp lại → patch im lặng không có tác dụng.
// Giờ dùng LPWhenClassReady + chỉ đánh dấu sau khi hook thành công.
//

static NSMutableSet<NSString *> *gPatched;

static BOOL LPPatchDone(NSString *key) {
    return [gPatched containsObject:key];
}

static NSDictionary *LPPatchFor(id self, SEL sel) {
    NSArray *list = [[LPConfig shared] obj:@"patches" fallback:@[]];
    NSString *cls = NSStringFromClass([self class]);
    NSString *s = NSStringFromSelector(sel);
    for (NSDictionary *p in list) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        NSString *c = p[@"class"] ?: @"";
        NSString *ps = p[@"selector"] ?: @"";
        if (![ps isEqualToString:s]) continue;
        if (c.length == 0 || [c isEqualToString:cls]) return p;
    }
    return nil;
}

#pragma mark - kiểu trả về

static double LPDouble(id self, SEL _cmd) {
    IMP o = LPOrigIMPFor(self, _cmd);
    double v = o ? ((double (*)(id, SEL))o)(self, _cmd) : 0;
    NSDictionary *p = LPPatchFor(self, _cmd);
    if (!p) return v;
    double val = [p[@"value"] doubleValue];
    NSString *mode = p[@"mode"] ?: @"clamp";
    if ([mode isEqualToString:@"clamp"] && v > val) {
        LPLog(@"[patch] %@.%@ %.2f -> %.2f", NSStringFromClass([self class]), NSStringFromSelector(_cmd), v, val);
        return val;
    }
    if ([mode isEqualToString:@"return"]) return val;
    return v;
}

static float LPFloat(id self, SEL _cmd) {
    IMP o = LPOrigIMPFor(self, _cmd);
    float v = o ? ((float (*)(id, SEL))o)(self, _cmd) : 0;
    NSDictionary *p = LPPatchFor(self, _cmd);
    if (!p) return v;
    float val = [p[@"value"] floatValue];
    NSString *mode = p[@"mode"] ?: @"clamp";
    if ([mode isEqualToString:@"clamp"] && v > val) return val;
    if ([mode isEqualToString:@"return"]) return val;
    return v;
}

static BOOL LPBool(id self, SEL _cmd) {
    IMP o = LPOrigIMPFor(self, _cmd);
    BOOL v = o ? ((BOOL (*)(id, SEL))o)(self, _cmd) : NO;
    NSDictionary *p = LPPatchFor(self, _cmd);
    if (!p) return v;
    NSString *mode = p[@"mode"] ?: @"true";
    if ([mode isEqualToString:@"false"]) return NO;
    if ([mode isEqualToString:@"true"]) return YES;
    return v;
}

static long long LPInt64(id self, SEL _cmd) {
    IMP o = LPOrigIMPFor(self, _cmd);
    long long v = o ? ((long long (*)(id, SEL))o)(self, _cmd) : 0;
    NSDictionary *p = LPPatchFor(self, _cmd);
    if (!p) return v;
    long long val = [p[@"value"] longLongValue];
    NSString *mode = p[@"mode"] ?: @"clamp";
    if ([mode isEqualToString:@"clamp"] && v > val) return val;
    if ([mode isEqualToString:@"return"]) return val;
    return v;
}

static id LPObject(id self, SEL _cmd) {
    IMP o = LPOrigIMPFor(self, _cmd);
    id v = o ? ((id (*)(id, SEL))o)(self, _cmd) : nil;
    NSDictionary *p = LPPatchFor(self, _cmd);
    if (!p) return v;
    id val = p[@"value"];
    NSString *mode = p[@"mode"] ?: @"clamp";
    if ([v isKindOfClass:[NSNumber class]] && [val respondsToSelector:@selector(doubleValue)]) {
        double cur = [v doubleValue];
        if ([mode isEqualToString:@"clamp"] && cur > [val doubleValue]) return @([val doubleValue]);
        if ([mode isEqualToString:@"return"]) return @([val doubleValue]);
    }
    if ([v isKindOfClass:[NSString class]] && [val isKindOfClass:[NSString class]] &&
        [mode isEqualToString:@"return"]) return val;
    return v;
}

#pragma mark - install

static void LPApply(NSDictionary *p) {
    NSString *clsName = p[@"class"] ?: @"";
    NSString *selName = p[@"selector"] ?: @"";
    if (!clsName.length || !selName.length) return;

    NSString *key = [NSString stringWithFormat:@"%@.%@", clsName, selName];
    if (LPPatchDone(key)) return;

    SEL sel = NSSelectorFromString(selName);
    LPWhenClassReady(clsName, ^(Class cls) {
        if (LPPatchDone(key)) return;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { LPLog(@"[patch] %@ không có %@", clsName, selName); return; }

        const char *enc = method_getTypeEncoding(m);
        char ret = enc ? enc[0] : 'v';
        IMP newImp = NULL;
        switch (ret) {
            case 'd': newImp = (IMP)LPDouble; break;
            case 'f': newImp = (IMP)LPFloat; break;
            case 'c': case 'B': newImp = (IMP)LPBool; break;
            case 'q': case 'Q': case 'i': case 'I': case 'l': case 'L': newImp = (IMP)LPInt64; break;
            case '@': newImp = (IMP)LPObject; break;
            default: break;
        }
        if (!newImp) { LPLog(@"[patch] bỏ qua %@ — kiểu '%c' chưa hỗ trợ", key, ret); return; }
        LPSetOrigIMP(cls, sel, method_getImplementation(m));
        method_setImplementation(m, newImp);
        [gPatched addObject:key];
        LPLog(@"[patch] %@ (kiểu '%c', mode %@)", key, ret, p[@"mode"] ?: @"clamp");
    });
}

void LPApplyConfiguredPatches(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gPatched = [NSMutableSet set]; });
    NSArray *patches = [[LPConfig shared] obj:@"patches" fallback:@[]];
    if (![patches isKindOfClass:[NSArray class]] || !patches.count) {
        LPLog(@"[patch] chưa có 'patches' trong config.plist");
        return;
    }
    for (NSDictionary *p in patches) if ([p isKindOfClass:[NSDictionary class]]) LPApply(p);
}

// Gọi lại sau khi người dùng sửa config (từ hub menu)
void LPReapplyPatches(void) {
    [[LPConfig shared] reload];
    [gPatched removeAllObjects];
    LPApplyConfiguredPatches();
}
