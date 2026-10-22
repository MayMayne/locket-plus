#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/stat.h>

#define LPLog(fmt, ...) [LPConfig log:(fmt), ##__VA_ARGS__]

@interface LPConfig : NSObject
@property (nonatomic, strong) NSDictionary *plist;
+ (instancetype)shared;
- (void)reload;
- (id)obj:(NSString *)key fallback:(id)fb;
- (double)dbl:(NSString *)key fallback:(double)fb;
- (BOOL)flag:(NSString *)key fallback:(BOOL)fb;
- (NSString *)str:(NSString *)key fallback:(NSString *)fb;
+ (NSString *)dir;
+ (NSString *)path:(NSString *)name;
+ (void)log:(NSString *)fmt, ...;
+ (NSString *)logText;
@end

// Giới hạn video mong muốn (đọc từ config.plist)
double LPVideoSeconds(void);
double LPVideoBytes(void);

void LPInstallCrashHandler(void);
void LPInstallMediaHooks(void);
void LPInstallFriendTools(void);
void LPInstallProfileUI(void);
void LPInstallProfileButton(UIViewController *vc);
void LPInstallExplorer(void);
void LPInstallGoldUnlock(void);
void LPInstallSideloadFixes(void);
void LPApplyConfiguredPatches(void);
void LPReapplyPatches(void);

// UI / tiện ích
void LPShowText(UIViewController *host, NSString *title, NSString *text);
void LPShowAlert(NSString *title, NSString *msg);
void LPShowHub(UIViewController *host);
void LPOpenExplorer(UIViewController *host);
void LPOpenProfile(UIViewController *host);
void LPRunFriendProbe(UIViewController *host);

// Bảng IMP gốc dùng chung cho mọi hook
void LPSetOrigIMP(Class cls, SEL sel, IMP imp);
IMP LPOrigIMPFor(id self, SEL sel);

// Móc an toàn: nếu class/method chưa tồn tại thì KHÔNG làm gì (không crash).
BOOL LPHookMethod(Class cls, SEL sel, IMP newImp, IMP *origOut);
// Tìm class đầu tiên trong danh sách có method (dùng cho class Swift đổi tên giữa các bản).
Class LPFindClassWithMethod(NSArray<NSString *> *names, SEL sel);

// Hook chờ class xuất hiện (Swift class thường chưa có lúc dylib nạp)
void LPWhenClassReady(NSString *className, void (^block)(Class cls));

@interface LPProfileModel : NSObject
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *quote;
@property (nonatomic, copy) NSString *songTitle;
@property (nonatomic, copy) NSString *songArtist;
@property (nonatomic, copy) NSString *lyrics;
@property (nonatomic, copy) NSString *coverName;   // tên file trong thư mục dữ liệu
@property (nonatomic, copy) NSString *avatarName;
@property (nonatomic, strong) NSMutableArray<NSString *> *featured;   // tên file
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *bestFriends; // name/note/image
+ (instancetype)load;
- (void)save;
@end
