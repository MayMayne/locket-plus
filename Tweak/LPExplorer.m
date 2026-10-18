#import "LPCommon.h"
#import <objc/runtime.h>

//
// LPExplorer — công cụ "tại chỗ" để tìm đúng chỗ cần hook trong Locket.
// Dùng khi tên class/method thật khác dự đoán.
// Mở từ nút nổi (chạm 2 lần) hoặc menu cài đặt của tweak.
//

static NSArray<NSString *> *LPAllClassNames(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int count = objc_getClassList(NULL, 0);
        Class *classes = (Class *)malloc(sizeof(Class) * count);
        count = objc_getClassList(classes, count);
        NSMutableArray *a = [NSMutableArray array];
        for (int i = 0; i < count; i++) {
            const char *n = class_getName(classes[i]);
            if (n) [a addObject:[NSString stringWithUTF8String:n]];
        }
        free(classes);
        names = [a sortedArrayUsingSelector:@selector(compare:)];
    });
    return names;
}

static NSArray<NSString *> *LPSearchClasses(NSString *kw) {
    if (!kw.length) return LPAllClassNames();
    NSString *k = kw.lowercaseString;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in LPAllClassNames()) {
        if ([n.lowercaseString containsString:k]) [out addObject:n];
        if (out.count > 400) break;
    }
    return out;
}

static void LPDumpClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) { LPShowAlert(@"Lỗi", @"Không có class này"); return; }
    NSMutableString *s = [NSMutableString stringWithFormat:@"Class %@\nSuper: %@\n\n", name,
                          NSStringFromClass(class_getSuperclass(cls))];
    Class cur = cls;
    int level = 0;
    while (cur && cur != [NSObject class] && level < 6) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(cur, &n);
        [s appendFormat:@"--- %@ (%u method) ---\n", NSStringFromClass(cur), n];
        for (unsigned int i = 0; i < n; i++) {
            [s appendFormat:@"  %c%s\n", method_getTypeEncoding(ms[i])[0], sel_getName(method_getName(ms[i]))];
        }
        free(ms);
        cur = class_getSuperclass(cur);
        level++;
    }
    LPShowText(nil, name, s);
}

static void LPSearchMethods(NSString *kw) {
    NSString *k = kw.lowercaseString;
    NSMutableString *s = [NSMutableString string];
    int hits = 0;
    for (NSString *cn in LPAllClassNames()) {
        if (![cn hasPrefix:@"LC"] && ![cn hasPrefix:@"LK"] && ![cn containsString:@"Locket"] &&
            ![cn containsString:@"Camera"] && ![cn containsString:@"Journal"] && ![cn containsString:@"Moment"]) continue;
        Class cls = NSClassFromString(cn);
        unsigned int n = 0;
        Method *ms = class_copyMethodList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[i]));
            if ([sel.lowercaseString containsString:k]) {
                [s appendFormat:@"%@  -%@\n", cn, sel];
                hits++;
            }
        }
        free(ms);
        if (hits > 500) break;
    }
    LPShowText(nil, [NSString stringWithFormat:@"'%@' — %d kết quả", kw, hits],
               hits ? s : @"Không thấy. Thử từ khoá khác: duration, video, recor, capture, limit, max, size.");
}

#pragma mark - UI

@interface LPExplorerViewController : UITableViewController <UISearchBarDelegate>
@property (nonatomic, copy) NSString *keyword;
@property (nonatomic, strong) NSArray<NSString *> *rows;
@property (nonatomic, assign) NSInteger mode;   // 0 = class, 1 = method scan
@end

@implementation LPExplorerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Runtime Explorer";
    UISearchBar *sb = [[UISearchBar alloc] init];
    sb.placeholder = @"Lọc class (VD: Record, Video, Capture)";
    sb.delegate = self;
    self.navigationItem.titleView = sb;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Quét method" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(toggleMode)];
    [self refresh];
}

- (void)toggleMode {
    self.mode = self.mode ? 0 : 1;
    self.title = self.mode ? @"Method scan" : @"Runtime Explorer";
    [self refresh];
}

- (void)refresh {
    if (self.mode) self.rows = @[]; else self.rows = LPSearchClasses(self.keyword);
    [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)t { self.keyword = t; [self refresh]; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.mode ? 1 : self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    if (self.mode) {
        c.textLabel.text = self.keyword.length ? [NSString stringWithFormat:@"Quét \"%@\"", self.keyword]
                                               : @"Nhập từ khoá (duration/video/size/record)";
        c.textLabel.numberOfLines = 0;
        c.detailTextLabel.text = @"Chạm để quét toàn bộ class Locket";
    } else {
        c.textLabel.text = self.rows[ip.row];
        c.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.mode) { LPSearchMethods(self.keyword ?: @"duration"); return; }
    LPDumpClass(self.rows[ip.row]);
}

@end

static UIViewController *LPResolveExplorerHost(UIViewController *host) {
    if (host) return host;
    UIWindow *w = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in ((UIWindowScene *)sc).windows) if (win.isKeyWindow) w = win;
    }
    return w.rootViewController;
}

void LPOpenExplorer(UIViewController *host) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = LPResolveExplorerHost(host);
        while (vc.presentedViewController) vc = vc.presentedViewController;
        LPExplorerViewController *e = [LPExplorerViewController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:e];
        [vc presentViewController:nav animated:YES completion:nil];
    });
}

#pragma mark - menu tổng

void LPShowHub(UIViewController *host) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = host;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Locket+"
                                                                  message:[NSString stringWithFormat:@"Video: %.0fs / %.0fMB",
                                                                           LPVideoSeconds(), LPVideoBytes() / 1048576.0]
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
        void (^add)(NSString *, void (^)(void)) = ^(NSString *t, void (^h)(void)) {
            [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { h(); }]];
        };
        add(@"👤 Mở Profile+", ^{ LPOpenProfile(vc); });
        add(@"🔍 Chẩn đoán kết bạn", ^{ LPRunFriendProbe(vc); });
        add(@"🧭 Runtime Explorer", ^{ LPOpenExplorer(vc); });
        add(@"📄 Xem log", ^{ LPShowText(nil, @"Locket+ log", [LPConfig logText]); });
        add(@"⚙️ Sửa config.plist", ^{ LPShowText(nil, @"config.plist", [NSString stringWithContentsOfFile:[LPConfig path:@"config.plist"] encoding:NSUTF8StringEncoding error:nil]); });
        add(@"♻️ Nạp lại config", ^{ [[LPConfig shared] reload];
            LPShowAlert(@"Locket+", [NSString stringWithFormat:@"Đã nạp lại.\nVideo %.0fs / %.0fMB",
                                     LPVideoSeconds(), LPVideoBytes() / 1048576.0]); });
        [a addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        if (a.popoverPresentationController) a.popoverPresentationController.sourceView = vc.view;
        [vc presentViewController:a animated:YES completion:nil];
    });
}
