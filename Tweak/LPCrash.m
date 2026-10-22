// ============================================================================
//  LPCrash.m — crash handler POSIX + boot counter
//
//  Bài học v2.1: crash handler dùng NSMutableString + writeToFile: thì CHẾT
//  luôn trong handler (Foundation không async-signal-safe) → crash.txt chỉ còn
//  template rỗng. Phải dùng open/read/write/snprintf.
//
//  Thêm: đếm số lần chết liên tiếp. >= 2 → tự bật safeMode để app luôn mở được.
// ============================================================================

#import "LPCommon.h"
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <execinfo.h>
#import <sys/stat.h>

static int gCrashFd = -1;
static volatile int gInHandler = 0;

static void LPRawWrite(const char *s) {
    if (!s || gCrashFd < 0) return;
    size_t n = strlen(s);
    ssize_t r = write(gCrashFd, s, n);
    (void)r;
}

static void LPWriteHex(uintptr_t v) {
    char buf[24];
    snprintf(buf, sizeof(buf), "0x%016lx", (unsigned long)v);
    LPRawWrite(buf);
}

static void LPSignalHandler(int sig, siginfo_t *info, void *ctx) {
    (void)ctx;
    if (gInHandler) { _exit(1); }
    gInHandler = 1;

    LPRawWrite("\n=== CRASH ===\n");
    char buf[96];
    snprintf(buf, sizeof(buf), "signal %d (%s) code %d\n",
             sig, strsignal(sig) ? strsignal(sig) : "?", info ? info->si_code : 0);
    LPRawWrite(buf);
    if (info) {
        LPRawWrite("fault addr ");
        LPWriteHex((uintptr_t)info->si_addr);
        LPRawWrite("\n");
    }

    // backtrace() dùng dladdr/malloc → không hoàn toàn async-signal-safe,
    // nhưng đây là đường cuối và đã chứng minh chạy được trên iOS.
    void *frames[48];
    int n = backtrace(frames, 48);
    for (int i = 0; i < n; i++) {
        LPRawWrite("#");
        char num[8];
        snprintf(num, sizeof(num), "%02d ", i);
        LPRawWrite(num);
        LPWriteHex((uintptr_t)frames[i]);
        LPRawWrite("\n");
    }
    LPRawWrite("=== END ===\n");

    if (gCrashFd >= 0) { fsync(gCrashFd); close(gCrashFd); gCrashFd = -1; }

    signal(sig, SIG_DFL);
    raise(sig);
}

static void LPExceptionHandler(NSException *e) {
    if (gInHandler) { _exit(1); }
    gInHandler = 1;

    if (gCrashFd < 0) {
        gCrashFd = open([LPPath(@"crash.txt") fileSystemRepresentation],
                        O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    LPRawWrite("\n=== OBJC EXCEPTION ===\n");
    LPRawWrite([[e name] UTF8String] ?: "?");
    LPRawWrite(": ");
    LPRawWrite([[e reason] UTF8String] ?: "?");
    LPRawWrite("\n");
    LPRawWrite([[[e callStackSymbols] componentsJoinedByString:@"\n"] UTF8String] ?: "");
    LPRawWrite("\n=== END ===\n");
    if (gCrashFd >= 0) { fsync(gCrashFd); close(gCrashFd); gCrashFd = -1; }
}

void LPWriteCrashText(NSString *text) {
    if (!text.length) return;
    int fd = open([LPPath(@"crash.txt") fileSystemRepresentation],
                  O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    const char *s = [text UTF8String];
    if (s) { ssize_t w = write(fd, s, strlen(s)); (void)w; }
    close(fd);
}

void LPInstallCrashHandler(void) {
    if (gCrashFd >= 0) return;
    gCrashFd = open([LPPath(@"crash.txt") fileSystemRepresentation],
                    O_WRONLY | O_CREAT | O_APPEND, 0644);

    NSSetUncaughtExceptionHandler(&LPExceptionHandler);

    static char altstack[SIGSTKSZ * 4];
    stack_t ss;
    ss.ss_sp = altstack;
    ss.ss_size = sizeof(altstack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = LPSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    int sigs[] = { SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGSYS };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
}

#pragma mark - boot counter

// Đếm số lần CHẾT LIÊN TIẾP — dựa trên kích thước crash.txt, không dựa vào
// số lần mở app.
//
// Vì sao không đếm theo số lần boot: user vuốt tắt app là chuyện thường, đếm
// kiểu đó sẽ bật safeMode sai sau 2 lần thoát bình thường.
//
// Cách đúng: crash handler APPEND vào crash.txt rồi fsync. Nếu lần boot này
// thấy crash.txt LỚN HƠN kích thước đã lưu ở lần boot trước → lần trước đã chết.
void LPBootBegin(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *crashPath = LPPath(@"crash.txt");
    NSString *sizePath  = LPPath(@"crash.size");
    NSString *countPath = LPPath(@"crash.count");

    unsigned long long now = 0;
    NSDictionary *attrs = [fm attributesOfItemAtPath:crashPath error:nil];
    if (attrs) now = [attrs[NSFileSize] unsignedLongLongValue];

    unsigned long long prev = 0;
    NSString *s = [NSString stringWithContentsOfFile:sizePath
                                            encoding:NSUTF8StringEncoding error:nil];
    if (s.length) prev = strtoull(s.UTF8String, NULL, 10);

    int n = [[NSString stringWithContentsOfFile:countPath
                                       encoding:NSUTF8StringEncoding error:nil] intValue];

    if (now > prev) {
        n++;                                  // lần trước đã chết
    } else {
        n = 0;                                // thoát sạch
    }

    if (n >= 2) {
        LPSetSafeMode(YES);
        LPLog(@"[boot] chết %d lần liên tiếp → safeMode", n);
        n = 0;
    }

    [[NSString stringWithFormat:@"%d", n]
        writeToFile:countPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [[NSString stringWithFormat:@"%llu", now]
        writeToFile:sizePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

void LPMarkBootOK(void) {
    [@"0" writeToFile:LPPath(@"crash.count") atomically:YES
             encoding:NSUTF8StringEncoding error:nil];

    // Boot sạch trong safeMode: đếm. Đủ 2 lần sạch liên tiếp thì tự tắt
    // safeMode để lần sau chạy đầy đủ. Không tắt ngay sau 1 lần: nếu lỗi là
    // ngẫu nhiên theo thời điểm, tắt ngay sẽ quay lại vòng crash.
    if (LPSafeMode()) {
        NSString *p = LPPath(@"safe_clean.count");
        int c = [[NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] intValue];
        c++;
        if (c >= 2) {
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
            LPSetSafeMode(NO);
            LPLog(@"[boot] 2 boot sạch trong safeMode → tắt safeMode");
        } else {
            [[NSString stringWithFormat:@"%d", c]
                writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            LPLog(@"[boot] boot sạch trong safeMode (%d/2)", c);
        }
    }
    LPLog(@"[boot] sẵn sàng");
}

#pragma mark - trace

void LPTrace(const char *what) {
    if (!what) return;
    if (![[LPConfig shared] flag:@"logVerbose" fallback:YES]) return;
    LPLog(@"[trace] %s", what);
}
