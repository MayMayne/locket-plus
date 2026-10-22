#import "LPCommon.h"
#import <signal.h>
#import <execinfo.h>

//
// LPCrash — bắt crash + tự bật chế độ an toàn.
//
// VẤN ĐỀ của cách cũ: dựa vào UIApplicationWillTerminateNotification để biết
// "lần trước thoát sạch". iOS KHÔNG gọi notification đó khi người dùng vuốt
// app khỏi app switcher → cờ còn lại → lần sau tưởng crash → bật safeMode
// vĩnh viễn (tweak chết im lặng).
//
// CÁCH MỚI: mốc "đã boot xong và sống 8 giây" (boot.ok).
//   • Đầu boot: xoá boot.ok
//   • Sau 8s chạy ổn: ghi boot.ok
//   • Lần mở sau: thiếu boot.ok + có boot.trace → lần trước chết giữa chừng
//     → bật safeMode, và ghi lại bước cuối cùng vào crash.txt
//

static NSString *LPDir(void) {
    NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [d stringByAppendingPathComponent:@"LocketPlus"];
}

static NSString *LPPath(NSString *name) {
    return [LPDir() stringByAppendingPathComponent:name];
}

void LPWriteCrashText(NSString *text) {
    [[NSFileManager defaultManager] createDirectoryAtPath:LPDir()
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:LPPath(@"crash.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - ghi crash

static void LPWriteCrash(const char *why, int sig) {
    // Không dùng Foundation ở đây: có thể đang ở giữa lúc heap hỏng.
    void *frames[64];
    int n = backtrace(frames, 64);
    char **syms = backtrace_symbols(frames, n);
    NSMutableString *s = [NSMutableString stringWithFormat:@"Locket+ crash: %s (signal %d)\n", why, sig];
    NSString *trace = [NSString stringWithContentsOfFile:LPPath(@"boot.trace")
                                                encoding:NSUTF8StringEncoding error:nil];
    if (trace.length) [s appendFormat:@"bước cuối: %@\n", trace];
    for (int i = 0; i < n; i++) [s appendFormat:@"%s\n", syms[i]];
    [s writeToFile:LPPath(@"crash.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void LPSignalHandler(int sig) {
    LPWriteCrash("signal", sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void LPExceptionHandler(NSException *e) {
    NSString *trace = [NSString stringWithContentsOfFile:LPPath(@"boot.trace")
                                                encoding:NSUTF8StringEncoding error:nil];
    NSString *s = [NSString stringWithFormat:@"Locket+ exception: %@\nreason: %@\nbước cuối: %@\n%@\n",
                   e.name, e.reason, trace ?: @"(không có)", e.callStackSymbols];
    LPWriteCrashText(s);
}

#pragma mark - boot ổn định

void LPInstallCrashHandler(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:LPDir() withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *okPath = LPPath(@"boot.ok");
    NSString *tracePath = LPPath(@"boot.trace");

    // Lần trước có boot nhưng không đạt mốc 8 giây → đã chết giữa chừng.
    BOOL hadTrace = [fm fileExistsAtPath:tracePath];
    BOOL hadOk = [fm fileExistsAtPath:okPath];
    if (hadTrace && !hadOk) {
        NSString *last = [NSString stringWithContentsOfFile:tracePath
                                                   encoding:NSUTF8StringEncoding error:nil];
        NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:[LPConfig path:@"config.plist"]] mutableCopy]
                                 ?: [NSMutableDictionary dictionary];
        d[@"safeMode"] = @YES;
        [d writeToFile:[LPConfig path:@"config.plist"] atomically:YES];
        LPWriteCrashText([NSString stringWithFormat:
            @"Lần chạy trước chết trước khi boot xong.\nbước cuối: %@\n\nĐã bật safeMode.\n"
            @"Xem log.txt để biết thêm. Tắt safeMode bằng cách sửa config.plist.",
            last ?: @"(không rõ)"]);
        NSLog(@"[Locket+] lần trước chết ở bước: %@", last);
    }

    // Đếm số lần chết liên tiếp. >=2 → lần sau không hook gì (cứu hộ khẩn cấp),
    // để app LUÔN mở được dù tweak có lỗi gì.
    NSString *countPath = LPPath(@"crash.count");
    int crashes = [[NSString stringWithContentsOfFile:countPath
                                            encoding:NSUTF8StringEncoding error:nil] intValue];
    if (hadTrace && !hadOk) {
        crashes++;
        [[NSString stringWithFormat:@"%d", crashes]
            writeToFile:countPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (crashes >= 2) {
            NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:[LPConfig path:@"config.plist"]] mutableCopy]
                                     ?: [NSMutableDictionary dictionary];
            d[@"safeMode"] = @YES;
            [d writeToFile:[LPConfig path:@"config.plist"] atomically:YES];
            NSLog(@"[Locket+] chết %d lần liên tiếp → khoá hook (safeMode)", crashes);
        }
    }

    // Bắt đầu lượt mới: xoá mốc, ghi trace trống.
    [fm removeItemAtPath:okPath error:nil];
    [fm removeItemAtPath:tracePath error:nil];

    NSSetUncaughtExceptionHandler(&LPExceptionHandler);
    signal(SIGSEGV, LPSignalHandler);
    signal(SIGABRT, LPSignalHandler);
    signal(SIGBUS, LPSignalHandler);
    signal(SIGILL, LPSignalHandler);
    signal(SIGFPE, LPSignalHandler);
}

// Gọi 8 giây sau boot: nếu app còn sống tới đây thì coi như boot thành công.
void LPMarkBootOK(void) {
    [[NSFileManager defaultManager] createDirectoryAtPath:LPDir()
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [@"ok" writeToFile:LPPath(@"boot.ok") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    // Boot sống 8 giây → reset bộ đếm crash.
    [[NSFileManager defaultManager] removeItemAtPath:LPPath(@"crash.count") error:nil];
}
