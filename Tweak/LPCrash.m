#import "LPCommon.h"
#import <signal.h>
#import <execinfo.h>

// Bắt crash và ghi ra Documents/LocketPlus/crash.txt TRƯỚC khi app chết.
// File này là thứ duy nhất cho biết chính xác hàm nào gây sập.

static void LPWriteCrash(const char *why, int sig) {
    // Không dùng Foundation ở đây: có thể đang ở giữa lúc heap hỏng.
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:@"LocketPlus/crash.txt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    void *frames[64];
    int n = backtrace(frames, 64);
    char **syms = backtrace_symbols(frames, n);
    NSMutableString *s = [NSMutableString stringWithFormat:@"Locket+ crash: %s (signal %d)\n", why, sig];
    for (int i = 0; i < n; i++) [s appendFormat:@"%s\n", syms[i]];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void LPSignalHandler(int sig) {
    LPWriteCrash("signal", sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void LPExceptionHandler(NSException *e) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:@"LocketPlus/crash.txt"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *s = [NSString stringWithFormat:@"Locket+ exception: %@\nreason: %@\n%@\n",
                   e.name, e.reason, e.callStackSymbols];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Đánh dấu "đang chạy"; nếu lần sau mở mà cờ vẫn còn → lần trước đã chết.
static NSString *LPSafeFlagPath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [[dir stringByAppendingPathComponent:@"LocketPlus"] stringByAppendingPathComponent:@"running.flag"];
}

void LPInstallCrashHandler(void) {
    // Nếu file cờ còn tồn tại từ lần chạy trước → app đã chết không sạch.
    NSString *flag = LPSafeFlagPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) {
        NSString *cfg = [LPConfig path:@"config.plist"];
        NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:cfg] mutableCopy] ?: [NSMutableDictionary dictionary];
        d[@"safeMode"] = @YES;
        [d writeToFile:cfg atomically:YES];
        NSLog(@"[Locket+] lần chạy trước không thoát sạch → bật safeMode");
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:[flag stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [@"1" writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSSetUncaughtExceptionHandler(&LPExceptionHandler);
    signal(SIGSEGV, LPSignalHandler);
    signal(SIGABRT, LPSignalHandler);
    signal(SIGBUS, LPSignalHandler);
    signal(SIGILL, LPSignalHandler);
    signal(SIGFPE, LPSignalHandler);
}
