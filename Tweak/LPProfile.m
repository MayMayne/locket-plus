#import "LPCommon.h"
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - Tiện ích ảnh

static NSString *LPSaveImage(UIImage *img, NSString *prefix) {
    if (!img) return nil;
    NSString *name = [NSString stringWithFormat:@"%@_%.0f.jpg", prefix, [NSDate date].timeIntervalSince1970 * 1000];
    NSData *d = UIImageJPEGRepresentation(img, 0.88);
    [d writeToFile:[LPConfig path:name] atomically:YES];
    return name;
}

static UIImage *LPImageNamed(NSString *name) {
    if (!name.length) return nil;
    return [UIImage imageWithContentsOfFile:[LPConfig path:name]];
}

#pragma mark - Huy hiệu bạn thân

@interface LPBadgeView : UIView
@property (nonatomic, copy) NSString *text;
@end

@implementation LPBadgeView
- (instancetype)initWithText:(NSString *)t {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 96, 22)])) {
        self.text = t ?: @"★ Bạn thân";
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 11;
        self.layer.masksToBounds = YES;
        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = self.bounds;
        g.colors = @[(id)[UIColor colorWithRed:1.0 green:0.78 blue:0.28 alpha:1].CGColor,
                     (id)[UIColor colorWithRed:0.98 green:0.55 blue:0.15 alpha:1].CGColor];
        g.startPoint = CGPointMake(0, 0); g.endPoint = CGPointMake(1, 1);
        [self.layer insertSublayer:g atIndex:0];
        UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
        l.text = self.text;
        l.font = [UIFont boldSystemFontOfSize:10];
        l.textColor = [UIColor colorWithRed:0.25 green:0.14 blue:0.02 alpha:1];
        l.textAlignment = NSTextAlignmentCenter;
        [self addSubview:l];
    }
    return self;
}
@end

#pragma mark - Màn hình profile

@interface LPProfilePresenter : NSObject
+ (instancetype)shared;
- (void)present;
- (void)presentDiagnostics;
@end

@interface LPProfileViewController : UIViewController <PHPickerViewControllerDelegate, UITextFieldDelegate>
@property (nonatomic, strong) LPProfileModel *model;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView *coverView, *avatarView;
@property (nonatomic, strong) UILabel *nameLabel, *quoteLabel, *songLabel, *lyricsLabel, *badgeLabel;
@property (nonatomic, strong) UIStackView *featuredStack, *friendsStack;
@property (nonatomic, copy) NSString *pickerTarget;   // cover / avatar / featured
@end

@implementation LPProfileViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.model = [LPProfileModel load];

    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.scroll];

    CGFloat W = self.view.bounds.size.width;

    // Ảnh bìa
    self.coverView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, W, 210)];
    self.coverView.contentMode = UIViewContentModeScaleAspectFill;
    self.coverView.clipsToBounds = YES;
    self.coverView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.coverView.userInteractionEnabled = YES;
    [self.coverView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(editCover)]];
    [self.scroll addSubview:self.coverView];

    // Avatar
    self.avatarView = [[UIImageView alloc] initWithFrame:CGRectMake(24, 150, 92, 92)];
    self.avatarView.contentMode = UIViewContentModeScaleAspectFill;
    self.avatarView.clipsToBounds = YES;
    self.avatarView.layer.cornerRadius = 46;
    self.avatarView.layer.borderWidth = 3;
    self.avatarView.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
    self.avatarView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.avatarView.userInteractionEnabled = YES;
    [self.avatarView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(editAvatar)]];
    [self.scroll addSubview:self.avatarView];

    // Nút đóng + sửa
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(W - 44, 12, 32, 32);
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor whiteColor];
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UIButton *edit = [UIButton buttonWithType:UIButtonTypeSystem];
    edit.frame = CGRectMake(W - 84, 12, 32, 32);
    [edit setImage:[UIImage systemImageNamed:@"pencil.circle.fill"] forState:UIControlStateNormal];
    edit.tintColor = [UIColor whiteColor];
    edit.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [edit addTarget:self action:@selector(editTexts) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:edit];

    // Tên + quote
    self.nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(130, 168, W - 150, 26)];
    self.nameLabel.font = [UIFont boldSystemFontOfSize:21];
    [self.scroll addSubview:self.nameLabel];

    self.badgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(130, 196, W - 150, 16)];
    self.badgeLabel.font = [UIFont systemFontOfSize:11];
    self.badgeLabel.textColor = [UIColor secondaryLabelColor];
    [self.scroll addSubview:self.badgeLabel];

    self.quoteLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 256, W - 48, 0)];
    self.quoteLabel.numberOfLines = 0;
    self.quoteLabel.font = [UIFont italicSystemFontOfSize:16];
    self.quoteLabel.textColor = [UIColor labelColor];
    [self.scroll addSubview:self.quoteLabel];

    [self buildSections];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    [self reload];
}

- (void)buildSections {
    CGFloat W = self.view.bounds.size.width;

    UILabel *songHead = [[UILabel alloc] initWithFrame:CGRectMake(24, 300, W - 48, 18)];
    songHead.text = @"🎵 BẢN NHẠC YÊU THÍCH";
    songHead.font = [UIFont boldSystemFontOfSize:11];
    songHead.textColor = [UIColor secondaryLabelColor];
    songHead.tag = 901;
    [self.scroll addSubview:songHead];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 322, W - 32, 0)];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 16;
    card.tag = 902;
    [self.scroll addSubview:card];

    self.songLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, W - 64, 0)];
    self.songLabel.numberOfLines = 0;
    self.songLabel.font = [UIFont boldSystemFontOfSize:15];
    [card addSubview:self.songLabel];

    self.lyricsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, W - 64, 0)];
    self.lyricsLabel.numberOfLines = 0;
    self.lyricsLabel.font = [UIFont systemFontOfSize:13];
    self.lyricsLabel.textColor = [UIColor secondaryLabelColor];
    [card addSubview:self.lyricsLabel];

    UILabel *featHead = [[UILabel alloc] initWithFrame:CGRectMake(24, 0, W - 48, 18)];
    featHead.text = @"📸 HÌNH ẢNH TIÊU BIỂU";
    featHead.font = [UIFont boldSystemFontOfSize:11];
    featHead.textColor = [UIColor secondaryLabelColor];
    featHead.tag = 903;
    [self.scroll addSubview:featHead];

    self.featuredStack = [[UIStackView alloc] initWithFrame:CGRectMake(24, 0, W - 48, 110)];
    self.featuredStack.axis = UILayoutConstraintAxisHorizontal;
    self.featuredStack.spacing = 10;
    [self.scroll addSubview:self.featuredStack];

    UILabel *friendHead = [[UILabel alloc] initWithFrame:CGRectMake(24, 0, W - 48, 18)];
    friendHead.text = @"💛 BẠN THÂN";
    friendHead.font = [UIFont boldSystemFontOfSize:11];
    friendHead.textColor = [UIColor secondaryLabelColor];
    friendHead.tag = 904;
    [self.scroll addSubview:friendHead];

    self.friendsStack = [[UIStackView alloc] initWithFrame:CGRectMake(24, 0, W - 48, 10)];
    self.friendsStack.axis = UILayoutConstraintAxisVertical;
    self.friendsStack.spacing = 10;
    [self.scroll addSubview:self.friendsStack];
}

- (void)reload {
    CGFloat W = self.view.bounds.size.width;
    self.model = [LPProfileModel load];

    self.coverView.image = LPImageNamed(self.model.coverName) ?: [[UIImage alloc] init];
    self.coverView.backgroundColor = self.model.coverName.length ? nil : [UIColor secondarySystemBackgroundColor];
    self.avatarView.image = LPImageNamed(self.model.avatarName);
    self.nameLabel.text = self.model.displayName.length ? self.model.displayName : @"Tên của bạn";
    self.badgeLabel.text = self.model.quote.length ? @"●" : @"Chạm bút chì để sửa";
    self.badgeLabel.text = @"";
    self.quoteLabel.text = [NSString stringWithFormat:@"“%@”", self.model.quote.length ? self.model.quote : @"Thêm câu quote của bạn…"];
    [self.quoteLabel sizeToFit];
    self.quoteLabel.frame = CGRectMake(24, 256, W - 48, self.quoteLabel.frame.size.height);

    CGFloat y = CGRectGetMaxY(self.quoteLabel.frame) + 26;

    UILabel *songHead = (UILabel *)[self.scroll viewWithTag:901];
    UIView *card = [self.scroll viewWithTag:902];
    UILabel *featHead = (UILabel *)[self.scroll viewWithTag:903];
    UILabel *friendHead = (UILabel *)[self.scroll viewWithTag:904];

    songHead.frame = CGRectMake(24, y, W - 48, 18);
    y += 26;

    NSString *song = self.model.songTitle.length
        ? [NSString stringWithFormat:@"%@%@", self.model.songTitle,
           self.model.songArtist.length ? [@" — " stringByAppendingString:self.model.songArtist] : @""]
        : @"Chưa chọn bài hát";
    self.songLabel.text = song;
    [self.songLabel sizeToFit];
    self.songLabel.frame = CGRectMake(16, 12, W - 64, self.songLabel.frame.size.height);

    self.lyricsLabel.text = self.model.lyrics.length ? self.model.lyrics : @"Thêm đoạn lyric bạn thích…";
    [self.lyricsLabel sizeToFit];
    self.lyricsLabel.frame = CGRectMake(16, CGRectGetMaxY(self.songLabel.frame) + 6, W - 64, self.lyricsLabel.frame.size.height);

    CGFloat cardH = CGRectGetMaxY(self.lyricsLabel.frame) + 14;
    card.frame = CGRectMake(16, y, W - 32, cardH);
    y = CGRectGetMaxY(card.frame) + 26;

    // Hình tiêu biểu
    featHead.frame = CGRectMake(24, y, W - 48, 18);
    y += 26;
    for (UIView *v in self.featuredStack.arrangedSubviews) { [self.featuredStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    for (NSString *name in self.model.featured) {
        UIImage *img = LPImageNamed(name);
        if (!img) continue;
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        iv.layer.cornerRadius = 12;
        iv.userInteractionEnabled = YES;
        [iv.widthAnchor constraintEqualToConstant:92].active = YES;
        [iv.heightAnchor constraintEqualToConstant:110].active = YES;
        UITapGestureRecognizer *lp = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(removeFeatured:)];
        [iv addGestureRecognizer:lp];
        [self.featuredStack addArrangedSubview:iv];
    }
    UIButton *addF = [UIButton buttonWithType:UIButtonTypeSystem];
    [addF setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    addF.backgroundColor = [UIColor secondarySystemBackgroundColor];
    addF.layer.cornerRadius = 12;
    [addF.widthAnchor constraintEqualToConstant:92].active = YES;
    [addF.heightAnchor constraintEqualToConstant:110].active = YES;
    [addF addTarget:self action:@selector(addFeatured) forControlEvents:UIControlEventTouchUpInside];
    [self.featuredStack addArrangedSubview:addF];
    self.featuredStack.frame = CGRectMake(24, y, W - 48, 110);
    y = CGRectGetMaxY(self.featuredStack.frame) + 26;

    // Bạn thân
    friendHead.frame = CGRectMake(24, y, W - 48, 18);
    y += 26;
    for (UIView *v in self.friendsStack.arrangedSubviews) { [self.friendsStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    for (NSMutableDictionary *f in self.model.bestFriends) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W - 48, 56)];
        row.backgroundColor = [UIColor secondarySystemBackgroundColor];
        row.layer.cornerRadius = 14;
        UIImageView *av = [[UIImageView alloc] initWithFrame:CGRectMake(8, 8, 40, 40)];
        av.layer.cornerRadius = 20; av.clipsToBounds = YES;
        av.contentMode = UIViewContentModeScaleAspectFill;
        av.image = LPImageNamed(f[@"image"]) ?: [UIImage systemImageNamed:@"person.crop.circle.fill"];
        [row addSubview:av];
        UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(58, 8, W - 200, 18)];
        nm.font = [UIFont boldSystemFontOfSize:14];
        nm.text = f[@"name"] ?: @"Bạn thân";
        [row addSubview:nm];
        UILabel *nt = [[UILabel alloc] initWithFrame:CGRectMake(58, 28, W - 200, 16)];
        nt.font = [UIFont systemFontOfSize:11];
        nt.textColor = [UIColor secondaryLabelColor];
        nt.text = f[@"note"] ?: @"";
        [row addSubview:nt];
        LPBadgeView *b = [[LPBadgeView alloc] initWithText:f[@"badge"] ?: @"★ Bạn thân"];
        b.frame = CGRectMake(W - 118, 17, 100, 22);
        [row addSubview:b];
        row.userInteractionEnabled = YES;
        [row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(removeFriend:)]];
        [self.friendsStack addArrangedSubview:row];
        [row.heightAnchor constraintEqualToConstant:56].active = YES;
    }
    UIButton *addB = [UIButton buttonWithType:UIButtonTypeSystem];
    [addB setTitle:@"  + Thêm bạn thân" forState:UIControlStateNormal];
    addB.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [addB addTarget:self action:@selector(addFriend) forControlEvents:UIControlEventTouchUpInside];
    [self.friendsStack addArrangedSubview:addB];
    [self.friendsStack layoutIfNeeded];
    self.friendsStack.frame = CGRectMake(24, y, W - 48, MAX(44, self.friendsStack.frame.size.height));
    y = CGRectGetMaxY(self.friendsStack.frame) + 40;

    self.scroll.contentSize = CGSizeMake(W, y);
}

#pragma mark - Hành động

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)editTexts {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Sửa profile" message:nil preferredStyle:UIAlertControllerStyleAlert];
    NSArray *fields = @[@"displayName", @"quote", @"songTitle", @"songArtist", @"lyrics"];
    NSArray *titles = @[@"Tên hiển thị", @"Quote", @"Tên bài hát", @"Ca sĩ", @"Lyric"];
    __block NSMutableArray *values = [NSMutableArray array];
    for (NSUInteger i = 0; i < fields.count; i++) {
        NSString *cur = [self.model valueForKey:fields[i]] ?: @"";
        [values addObject:cur];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = titles[i];
            tf.text = cur;
            tf.tag = (NSInteger)i;
            [[NSNotificationCenter defaultCenter] addObserverForName:UITextFieldTextDidChangeNotification
                                                              object:tf queue:nil
                                                          usingBlock:^(NSNotification *n) {
                if (tf.tag < (NSInteger)values.count) values[tf.tag] = tf.text ?: @"";
            }];
        }];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        for (NSUInteger i = 0; i < fields.count; i++) [self.model setValue:values[i] forKey:fields[i]];
        [self.model save];
        [self reload];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickImageFor:(NSString *)target {
    self.pickerTarget = target;
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter imagesFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)editCover { [self pickImageFor:@"cover"]; }
- (void)editAvatar { [self pickImageFor:@"avatar"]; }
- (void)addFeatured { [self pickImageFor:@"featured"]; }

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSItemProvider *prov = results.firstObject.itemProvider;
    NSString *target = self.pickerTarget;
    [prov loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *err) {
        if (!img) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([target isEqualToString:@"cover"]) self.model.coverName = LPSaveImage(img, @"cover");
            else if ([target isEqualToString:@"avatar"]) self.model.avatarName = LPSaveImage(img, @"avatar");
            else {
                NSString *n = LPSaveImage(img, @"featured");
                if (n) [self.model.featured addObject:n];
            }
            [self.model save];
            [self reload];
        });
    }];
}

- (void)removeFeatured:(UITapGestureRecognizer *)g {
    NSInteger idx = [self.featuredStack.arrangedSubviews indexOfObject:g.view];
    if (idx >= 0 && idx < (NSInteger)self.model.featured.count) {
        [self.model.featured removeObjectAtIndex:idx];
        [self.model save];
        [self reload];
    }
}

- (void)addFriend {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Thêm bạn thân" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"Tên"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"Ghi chú (VD: học cùng lớp)"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"Huy hiệu (VD: ★ Bestie)"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"Tiếp: chọn ảnh" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        NSString *name = a.textFields[0].text ?: @"Bạn thân";
        NSString *note = a.textFields[1].text ?: @"";
        NSString *badge = a.textFields[2].text.length ? a.textFields[2].text : @"★ Bạn thân";
        NSMutableDictionary *f = [@{@"name": name, @"note": note, @"badge": badge} mutableCopy];
        [self.model.bestFriends addObject:f];
        [self.model save];
        [self reload];
        [self pickImageFor:@"friend"];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)removeFriend:(UITapGestureRecognizer *)g {
    NSInteger idx = [self.friendsStack.arrangedSubviews indexOfObject:g.view];
    if (idx < 0 || idx >= (NSInteger)self.model.bestFriends.count) return;
    [self.model.bestFriends removeObjectAtIndex:idx];
    [self.model save];
    [self reload];
}

@end

#pragma mark - Hook vào menu profile của Locket

static BOOL LPIsProfileMenu(id vc) {
    NSString *cls = NSStringFromClass([vc class]);
    return [cls containsString:@"ProfileMenuV2"] || [cls containsString:@"ProfileMenu"];
}

static void LPViewDidAppear(id self, SEL _cmd, BOOL animated) {
    IMP o = LPOrigIMPFor(self, _cmd);
    if (o) ((void (*)(id, SEL, BOOL))o)(self, _cmd, animated);
    if (!LPIsProfileMenu(self)) return;
    UIView *host = ((UIViewController *)self).view;
    if (!host || [host viewWithTag:0x4C50504C]) return;   // LPPL
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = 0x4C50504C;
    b.frame = CGRectMake(20, host.bounds.size.height - 90, 56, 56);
    b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin;
    [b setImage:[UIImage systemImageNamed:@"sparkles"] forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    b.backgroundColor = [UIColor colorWithRed:0.98 green:0.55 blue:0.15 alpha:1];
    b.layer.cornerRadius = 28;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.25;
    b.layer.shadowRadius = 8;
    b.layer.shadowOffset = CGSizeMake(0, 3);
    [b addTarget:[LPProfilePresenter shared] action:@selector(present) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[LPProfilePresenter shared] action:@selector(presentDiagnostics)];
    [b addGestureRecognizer:lp];
    [host addSubview:b];
    LPLog(@"[ui] đã gắn nút Profile+ vào %@", NSStringFromClass([self class]));
}

@implementation LPProfilePresenter
+ (instancetype)shared {
    static LPProfilePresenter *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [LPProfilePresenter new]; });
    return s;
}
- (UIViewController *)top {
    UIWindow *w = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:[UIWindowScene class]])
            for (UIWindow *win in ((UIWindowScene *)sc).windows) if (win.isKeyWindow) w = win;
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
- (void)present {
    LPProfileViewController *p = [LPProfileViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:p];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [[self top] presentViewController:nav animated:YES completion:nil];
}
- (void)presentDiagnostics {
    LPRunFriendProbe([self top]);
}
@end

void LPOpenProfile(UIViewController *host) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = host;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        LPProfileViewController *p = [LPProfileViewController new];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:p];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [vc presentViewController:nav animated:YES completion:nil];
    });
}

void LPInstallProfileUI(void) {
    Class cls = NSClassFromString(@"_TtC14JournalFeature27ProfileMenuV2ViewController");
    if (!cls) { cls = NSClassFromString(@"ProfileMenuV2ViewController"); }
    if (!cls) { LPLog(@"[ui] KHÔNG tìm thấy ProfileMenuV2ViewController — chỉ dùng menu nổi"); return; }
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        LPSetOrigIMP(cls, sel, method_getImplementation(m));
        method_setImplementation(m, (IMP)LPViewDidAppear);
        LPLog(@"[ui] hook %@ viewDidAppear:", NSStringFromClass(cls));
    }
}
