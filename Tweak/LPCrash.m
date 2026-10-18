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

void LPInstallCrashHandler(void) {
    NSSetUncaughtExceptionHandler(&LPExceptionHandler);
    signal(SIGSEGV, LPSignalHandler);
    signal(SIGABRT, LPSignalHandler);
    signal(SIGBUS, LPSignalHandler);
    signal(SIGILL, LPSignalHandler);
    signal(SIGFPE, LPSignalHandler);
}
