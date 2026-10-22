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

    // Ghi số lần chết trước khi thoát — dùng path tuyệt đối, không Foundation.
    char path[512];
    const char *docs = getenv("HOME");
    if (docs) {
        snprintf(path, sizeof(path), "%s/Documents/LocketPlus/crash.count", docs);
        int fd = open(path, O_RDWR | O_CREAT, 0644);
        if (fd >= 0) {
            char c[16] = {0};
            ssize_t r = read(fd, c, sizeof(c) - 1);
            int v = (r > 0) ? atoi(c) : 0;
            v++;
            lseek(fd, 0, SEEK_SET);
            ftruncate(fd, 0);
            char out[16];
            int len = snprintf(out, sizeof(out), "%d", v);
            ssize_t w = write(fd, out, (size_t)len);
            (void)w;
            close(fd);
        }
    }

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

// Đếm số lần chết LIÊN TIẾP.
//   LPBootBegin   : đọc count cũ; >= 2 → safeMode; rồi ghi count+1
//   LPMarkBootOK  : ghi 0 (boot xong mới reset)
// Nhờ vậy: boot1 ghi 1 → chết; boot2 đọc 1, ghi 2 → chết; boot3 đọc 2 → safeMode.
// (Bản trước reset ngay trong LPBootBegin nên count không bao giờ lên tới 2.)
void LPBootBegin(void) {
    NSString *p = LPPath(@"crash.count");
    int v = [[NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] intValue];
    if (v >= 2) {
        LPSetSafeMode(YES);
        LPLog(@"[boot] chết %d lần liên tiếp → safeMode", v);
        v = 0;
    }
    [[NSString stringWithFormat:@"%d", v + 1]
        writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
