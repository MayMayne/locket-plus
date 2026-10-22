// ============================================================================
//  LocketPlus v5.0 — LPCommon.h
//
//  Một dylib duy nhất thay cho 4 dylib mẫu:
//    blatantsPatch.dylib   → sống sót sideload (keychain + app group)
//    AutoRcSideload.dylib  → mở khoá Gold (rewrite JSON RevenueCat ở tầng mạng)
//    MHVideoPipeline.dylib → trần quay + composition tỉ lệ khung
//    MHProfileVideo.dylib  → (không gộp: video bìa profile, không ai yêu cầu)
//
//  NGUYÊN TẮC AN TOÀN (rút ra từ 6 bản crash trước):
//    1. Không MSHookFunction. Không vá mã máy. Chỉ swizzle ObjC + fishhook __got.
//    2. Không hook getter trả struct > 16 byte (CMTime, CMTimeRange, CGRect).
//       Chỉ hook SETTER nhận struct làm THAM SỐ.
//    3. Không hook method trả về instancetype từ họ "init" (ARC sai quy ước
//       +1/+0 → over-release). Vì vậy KHÔNG hook initWithAsset:presetName:;
//       cấu hình session ở exportAsynchronouslyWithCompletionHandler:.
//    4. Mọi hook tra Method bằng class_copyMethodList để biết class nào SỞ HỮU,
//       không dùng class_getInstanceMethod (nó đi lên cha → sửa Method của cha).
//    5. Mọi hook bọc @try/@catch. Không hook gì trong constructor trừ crash
//       handler + vá keychain (2 thứ buộc phải chạy trước Firebase Auth).
//    6. Chết 2 lần liên tiếp → tự bật safeMode (chỉ log, không hook gì).
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define LPLog(fmt, ...) [LPConfig log:(fmt), ##__VA_ARGS__]

#pragma mark - cấu hình

@interface LPConfig : NSObject
@property (nonatomic, strong) NSDictionary *plist;
+ (instancetype)shared;
- (void)reload;
- (BOOL)flag:(NSString *)key fallback:(BOOL)fb;
- (double)dbl:(NSString *)key fallback:(double)fb;
- (NSString *)str:(NSString *)key fallback:(NSString *)fb;
- (id)obj:(NSString *)key;
+ (void)log:(NSString *)fmt, ...;
+ (NSString *)logText;
@end

NSString *LPDir(void);
NSString *LPPath(NSString *name);
NSString *LPGroupPathFor(NSString *groupID);

BOOL LPSafeMode(void);
void LPSetSafeMode(BOOL on);

double LPMaxRecordSeconds(void);
double LPMaxRecordBytes(void);
double LPUploadSeconds(void);
double LPUploadBytes(void);

#pragma mark - hook an toàn

BOOL LPHookMethod(Class cls, SEL sel, IMP newImp, IMP *origOut);
BOOL LPHookMethodTyped(Class cls, SEL sel, const char *expectReturn,
                       IMP newImp, IMP *origOut);
IMP  LPOrigIMPFor(id self, SEL sel);
void LPWhenClassReady(NSString *name, void (^block)(Class cls));

#pragma mark - tầng mạng dùng chung

@interface LPNetResult : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) NSURLResponse *response;
@end

typedef void (^LPNetProcessor)(NSURLRequest *req, LPNetResult *res);

void LPAddNetProcessor(LPNetProcessor processor);
void LPInstallNetHooks(void);

#pragma mark - các module

void LPInstallCrashHandler(void);
void LPWriteCrashText(NSString *text);
void LPBootBegin(void);
void LPMarkBootOK(void);
void LPTrace(const char *what);

void LPInstallSideloadFixes(void);
void LPWatchdogStart(void);
void LPInstallGold(void);
void LPInstallMedia(void);
void LPInstallUpload(void);
void LPInstallProbe(void);
