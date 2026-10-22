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

#pragma mark - ghi crash

void LPWriteCrashText(NSString *text) {
    if (!text) return;
    [text writeToFile:LPPath(@"crash.txt") atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
}

static void LPWriteCrash(const char *why, int sig) {
    // Chỉ dùng hàm async-signal-safe tối thiểu; Foundation ở đây có thể chết
    // nếu crash xảy ra khi heap hỏng → bọc @try và bỏ qua nếu fail.
    @try {
        void *frames[64];
        int n = backtrace(frames, 64);
        NSMutableString *s = [NSMutableString stringWithFormat:
            @"Locket+ crash: %s (signal %d)\n", why, sig];
        NSString *trace = [NSString stringWithContentsOfFile:LPPath(@"boot.trace")
                                                    encoding:NSUTF8StringEncoding error:nil];
        if (trace.length) [s appendFormat:@"bước cuối: %@\n", trace];
        char **syms = backtrace_symbols(frames, n);
        if (syms) {
            for (int i = 0; i < n; i++) [s appendFormat:@"%s\n", syms[i]];
            free(syms);
        }
        LPWriteCrashText(s);
    } @catch (__unused NSException *e) {}
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
