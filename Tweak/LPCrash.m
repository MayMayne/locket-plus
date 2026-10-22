// ============================================================================
//  LPCrash.m — bắt crash, ghi bằng POSIX (không Foundation)
//
//  Vì sao POSIX: trong signal handler, Foundation có thể chết (heap hỏng,
//  lock bị giữ). Bản trước dùng NSMutableString + writeToFile → crash.txt chỉ
//  còn template rỗng, không có stack trace.
//
//  Cơ chế boot.ok: iOS KHÔNG gọi UIApplicationWillTerminate khi user vuốt app
//  khỏi app switcher → không thể dùng nó để biết "lần trước thoát sạch".
//  Dùng mốc "đã sống 8 giây".
// ============================================================================

#import "LPCommon.h"
#import <signal.h>
#import <execinfo.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>

static void LPWriteCrash(const char *why, int sig) {
    char buf[8192];
    int n = 0;

    n += snprintf(buf + n, sizeof(buf) - (size_t)n,
                  "Locket+ crash: %s (signal %d)\n", why, sig);

    int fd = open(LPPath(@"boot.trace").fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
        n += snprintf(buf + n, sizeof(buf) - (size_t)n, "bước cuối: ");
        ssize_t r = read(fd, buf + n, sizeof(buf) - (size_t)n - 2);
        if (r > 0) n += (int)r;
        close(fd);
        if (n > 0 && buf[n - 1] != '\n') buf[n++] = '\n';
    }

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

static void LPSignal(int sig) {
    LPWriteCrash("signal", sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void LPException(NSException *e) {
    // Exception của ObjC xảy ra trên thread bình thường → Foundation an toàn ở đây.
    @try {
        NSString *trace = [NSString stringWithContentsOfFile:LPPath(@"boot.trace")
                                                    encoding:NSUTF8StringEncoding error:nil];
        NSString *s = [NSString stringWithFormat:
            @"Locket+ exception: %@\nreason: %@\nbước cuối: %@\n%@\n",
            e.name, e.reason, trace ?: @"(không có)", e.callStackSymbols];
        [s writeToFile:LPPath(@"crash.txt") atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    } @catch (__unused NSException *e2) {}
}

void LPBootStep(const char *name) {
    @try {
        NSString *p = LPPath(@"boot.trace");
        NSData *d = [[NSString stringWithFormat:@"%s\n", name]
                     dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) { [d writeToFile:p atomically:YES]; return; }
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (__unused NSException *e) {}
}

void LPInstallCrashHandler(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *okPath = LPPath(@"boot.ok");
    NSString *tracePath = LPPath(@"boot.trace");
    BOOL hadTrace = [fm fileExistsAtPath:tracePath];
    BOOL hadOk = [fm fileExistsAtPath:okPath];

    if (hadTrace && !hadOk) {
        NSString *last = [NSString stringWithContentsOfFile:tracePath
                                                   encoding:NSUTF8StringEncoding error:nil];
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
            NSLog(@"[Locket+] chết %d lần → safeMode", crashes);
        }
        NSLog(@"[Locket+] lần trước chết ở: %@", last);
    }

    [fm removeItemAtPath:okPath error:nil];
    [fm removeItemAtPath:tracePath error:nil];

    NSSetUncaughtExceptionHandler(&LPException);
    signal(SIGSEGV, LPSignal);
    signal(SIGABRT, LPSignal);
    signal(SIGBUS, LPSignal);
    signal(SIGILL, LPSignal);
    signal(SIGFPE, LPSignal);
    signal(SIGTRAP, LPSignal);
}

void LPMarkBootOK(void) {
    [@"ok" writeToFile:LPPath(@"boot.ok") atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:LPPath(@"crash.count") error:nil];
}
