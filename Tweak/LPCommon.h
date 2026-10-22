// ============================================================================
//  LocketPlus v2.0 — LPCommon.h
//
//  Một dylib duy nhất, bám sát 3 dylib mẫu đã disassemble:
//    • blatantsPatch.dylib  → sống sót sideload (app group + keychain)
//    • AutoRcSideload.dylib → mở khoá Gold (rewrite JSON của RevenueCat)
//    • MHVideoPipeline.dylib→ trần quay 600s / 500MB + preset ladder
//
//  Nguyên tắc: KHÔNG hook gì khi class/method không tồn tại, KHÔNG hook getter
//  trả struct, KHÔNG dùng MSHookFunction, mọi hook đều bọc @try/@catch.
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
+ (NSString *)dir;
+ (NSString *)path:(NSString *)name;
+ (void)log:(NSString *)fmt, ...;
+ (NSString *)logText;
@end

NSString *LPDir(void);
NSString *LPPath(NSString *name);

// Thư mục thay thế cho app-group (app group thật không tồn tại khi sideload).
NSString *LPGroupPathFor(NSString *groupID);

// Giới hạn video (đọc từ config.plist)
double LPVideoSeconds(void);
double LPVideoBytes(void);

#pragma mark - hook an toàn

void LPSetOrigIMP(Class cls, SEL sel, IMP imp);
IMP  LPOrigIMPFor(id self, SEL sel);
IMP  LPOrigIMPForClass(Class cls, SEL sel);

// Hook chỉ khi class + method tồn tại. Trả NO nếu bỏ qua.
BOOL LPHookMethod(Class cls, SEL sel, IMP newImp, IMP *origOut);

// Như trên nhưng chỉ hook khi ký tự đầu của type encoding khớp (an toàn kiểu).
BOOL LPHookMethodTyped(Class cls, SEL sel, const char *expectReturn,
                       IMP newImp, IMP *origOut);

// Hook trên class trừu tượng + class cụ thể (NSURLSession là class cluster).
BOOL LPHookClassAndConcrete(Class cls, const char *concreteName,
                            SEL sel, IMP newImp, IMP *origOut);

// Chờ class xuất hiện (Swift class nạp muộn), tối đa 30s.
void LPWhenClassReady(NSString *className, void (^block)(Class cls));

#pragma mark - tầng mạng dùng chung

// Một kết quả mạng có thể bị nhiều bộ xử lý sửa lần lượt.
@interface LPNetResult : NSObject
@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) NSURLResponse *response;
@end

typedef void (^LPNetProcessor)(NSURLRequest *req, LPNetResult *res);

void LPAddNetProcessor(LPNetProcessor processor);
void LPInstallNetHooks(void);

#pragma mark - các module

void LPInstallCrashHandler(void);
void LPMarkBootOK(void);
void LPWriteCrashText(NSString *text);
void LPBootStep(const char *name);
void LPTrace(const char *what);
void LPInstallSideloadFixes(void);
void LPInstallMediaHooks(void);
void LPInstallGoldNetProcessor(void);
void LPInvalidateRevenueCatCacheOnce(void);
void LPInstallFriendTools(void);
void LPInstallFriendNetProcessor(void);
void LPRunFriendProbe(void);
