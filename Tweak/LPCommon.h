// ============================================================================
//  LocketPlus v3.0 — CHỈ LÀM 2 VIỆC
//    1. Sống sót sideload  (copy nguyên blatantsPatch.dylib)
//    2. Trần quay 600s / 500MB
//
//  KHÔNG có: Gold, kết bạn, Remote Config, mic, audio session, profile UI,
//  export preset ladder, hook NSURLSession. Mỗi thứ đó là một đường dẫn crash
//  và không ai yêu cầu.
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define LPLog(fmt, ...) [LPConfig log:(fmt), ##__VA_ARGS__]

@interface LPConfig : NSObject
@property (nonatomic, strong) NSDictionary *plist;
+ (instancetype)shared;
- (BOOL)flag:(NSString *)key fallback:(BOOL)fb;
- (double)dbl:(NSString *)key fallback:(double)fb;
+ (NSString *)dir;
+ (NSString *)path:(NSString *)name;
+ (void)log:(NSString *)fmt, ...;
@end

NSString *LPDir(void);
NSString *LPPath(NSString *name);
NSString *LPGroupPathFor(NSString *groupID);

double LPVideoSeconds(void);
double LPVideoBytes(void);

// Hook an toàn — dùng class_copyMethodList như _Hook @0x8364 của
// MHVideoPipeline và _ObserveMethod @0x4570 của blatantsPatch.
BOOL LPHookMethod(Class cls, SEL sel, IMP newImp, IMP *origOut);
BOOL LPHookMethodTyped(Class cls, SEL sel, const char *expectReturn,
                       IMP newImp, IMP *origOut);
IMP  LPOrigIMPFor(Class cls, SEL sel);

void LPInstallCrashHandler(void);
void LPMarkBootOK(void);
void LPInstallSideloadFixes(void);
void LPInstallMediaHooks(void);
