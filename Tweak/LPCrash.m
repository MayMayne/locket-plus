// ============================================================================
//  LPCrash.m — bắt crash + tự bật chế độ an toàn
//
//  Vì sao dùng boot.ok thay vì UIApplicationWillTerminateNotification:
//  iOS KHÔNG gọi notification đó khi người dùng vuốt app khỏi app switcher →
//  cờ còn lại → lần sau tưởng crash → safeMode bật vĩnh viễn (tweak chết im).
//
//  Cơ chế:
//    • Đầu boot: xoá boot.ok + boot.trace
//    • Ghi từng bước vào boot.trace (flush ngay)
//    • Sau 8s sống sót: ghi boot.ok
//    • Lần mở sau: có trace mà thiếu ok → lần trước chết giữa chừng
//      → tăng crash.count; >=2 → safeMode
// ============================================================================

#import "LPCommon.h"
#import <signal.h>
#import <execinfo.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

#pragma mark - ghi crash

void LPWriteCrashText(NSString *text) {
    if (!text) return;
    [text writeToFile:LPPath(@"crash.txt") atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
}

static void LPWriteCrash(const char *why, int sig) {
    // Trong signal handler, Foundation/ObjC CÓ THỂ chết (heap hỏng, lock giữ).
    // Bản trước dùng NSMutableString + writeToFile → handler chết luôn, và ta
    // chỉ nhận được template rỗng. Giờ dùng syscall trực tiếp, không ObjC.
    char buf[8192];
    int n = 0;

    n += snprintf(buf + n, sizeof(buf) - (size_t)n,
                  "Locket+ crash: %s (signal %d)\n", why, sig);

    // Bước boot cuối — đọc bằng open/read thuần.
    int fd = open(LPPath(@"boot.trace").fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
        n += snprintf(buf + n, sizeof(buf) - (size_t)n, "bước cuối: ");
        ssize_t r = read(fd, buf + n, sizeof(buf) - (size_t)n - 2);
        if (r > 0) n += (int)r;
        close(fd);
        if (n > 0 && buf[n - 1] != '\n') buf[n++] = '\n';
    }

    // Stack trace: backtrace_symbols cấp phát bộ nhớ → dùng backtrace() thô.
    void *frames[64];
    int count = backtrace(frames, 64);
    for (int i = 0; i < count && n < (int)sizeof(buf) - 32; i++) {
        n += snprintf(buf + n, sizeof(buf) - (size_t)n, "  #%d %p\n", i, frames[i]);
    }

    int out = open(LPPath(@"crash.txt").fileSystemRepresentation,
                   O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out >= 0) {
        ssize_t ignored = write(out, buf, (size_t)n);
        (void)ignored;
        close(out);
    }
}

static void LPSignalHandler(int sig) {
    LPWriteCrash("signal", sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void LPExceptionHandler(NSException *e) {
    @try {
        NSString *trace = [NSString stringWithContentsOfFile:LPPath(@"boot.trace")
                                                    encoding:NSUTF8StringEncoding error:nil];
        NSString *s = [NSString stringWithFormat:
            @"Locket+ exception: %@\nreason: %@\nbước cuối: %@\n%@\n",
            e.name, e.reason, trace ?: @"(không có)", e.callStackSymbols];
        LPWriteCrashText(s);
    } @catch (__unused NSException *e2) {}
}

#pragma mark - boot trace

void LPBootStep(const char *name) {
    @try {
        NSString *p = LPPath(@"boot.trace");
        NSString *line = [NSString stringWithFormat:@"%s\n", name];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) { [d writeToFile:p atomically:YES]; return; }
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (__unused NSException *e) {}
}

// Ghi "đang chạy tới đây" sau khi boot xong. Không có cái này thì crash sau
// boot chỉ để lại boot.trace đã đủ bước "done" — không biết chết ở đâu.
// Gọi từ các điểm nghi ngờ (hook chạy lần đầu, processor chạy lần đầu...).
void LPTrace(const char *what) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    [lock lock];
    @try {
        NSString *p = LPPath(@"live.trace");
        NSString *line = [NSString stringWithFormat:@"%s\n", what];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) { [d writeToFile:p atomically:YES]; }
        else {
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
            NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
            if ([a[NSFileSize] unsignedLongLongValue] > 64 * 1024) {
                [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
            }
        }
    } @catch (__unused NSException *e) {}
    [lock unlock];
}

#pragma mark - install

void LPInstallCrashHandler(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    (void)fm;

    NSString *okPath = LPPath(@"boot.ok");
    NSString *tracePath = LPPath(@"boot.trace");
    BOOL hadTrace = [fm fileExistsAtPath:tracePath];
    BOOL hadOk = [fm fileExistsAtPath:okPath];

    if (hadTrace && !hadOk) {
        NSString *last = [NSString stringWithContentsOfFile:tracePath
                                                   encoding:NSUTF8StringEncoding error:nil];
        // Đếm số lần chết liên tiếp.
        NSString *countPath = LPPath(@"crash.count");
        int crashes = [[NSString stringWithContentsOfFile:countPath
                                                encoding:NSUTF8StringEncoding error:nil] intValue] + 1;
        [[NSString stringWithFormat:@"%d", crashes]
            writeToFile:countPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        if (crashes >= 2) {
            NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:LPPath(@"config.plist")] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
            d[@"safeMode"] = @YES;
            [d writeToFile:LPPath(@"config.plist") atomically:YES];
            [LPConfig shared].plist = d;
            NSLog(@"[Locket+] chết %d lần → safeMode", crashes);
        }

        LPWriteCrashText([NSString stringWithFormat:
            @"Lần chạy trước chết trước khi boot xong (lần %d).\nbước cuối: %@\n\n"
            @"Xem log.txt. safeMode=%@ trong Documents/LocketPlus/config.plist.",
            crashes, last ?: @"(không rõ)", crashes >= 2 ? @"YES" : @"NO"]);
    }

    // Lượt mới.
    [fm removeItemAtPath:okPath error:nil];
    [fm removeItemAtPath:tracePath error:nil];

    NSSetUncaughtExceptionHandler(&LPExceptionHandler);
    signal(SIGSEGV, LPSignalHandler);
    signal(SIGABRT, LPSignalHandler);
    signal(SIGBUS, LPSignalHandler);
    signal(SIGILL, LPSignalHandler);
    signal(SIGFPE, LPSignalHandler);
    signal(SIGTRAP, LPSignalHandler);
}

void LPMarkBootOK(void) {
    [@"ok" writeToFile:LPPath(@"boot.ok") atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    // Boot sống 8s → reset bộ đếm.
    [[NSFileManager defaultManager] removeItemAtPath:LPPath(@"crash.count") error:nil];
}
