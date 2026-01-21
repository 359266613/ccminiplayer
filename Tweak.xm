// Tweak.xm
// iOS 16.5 + Dopamine(rootless) 友好
// 功能：控制中心 Now Playing 显示层替换：极简条形 + 渐变/粒子背景
// 重点：不 remove 原生 view，只隐藏（保留原生控制链），降低崩溃风险

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>

#pragma mark - ===== Prefs =====

static NSString * const kCSPrefsID = @"com.axs.ccminiplayer";
static NSString * const kCSPrefsChangedDarwin = @"com.axs.ccminiplayer/prefsChanged";

static BOOL CSBoolPref(NSString *key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kCSPrefsID);
    if (!v) return def;
    BOOL b = def;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) b = CFBooleanGetValue((CFBooleanRef)v);
    CFRelease(v);
    return b;
}

static double CSDoublePref(NSString *key, double def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kCSPrefsID);
    if (!v) return def;
    double d = def;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d);
    CFRelease(v);
    return d;
}

static void CSSyncPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kCSPrefsID);
}

#pragma mark - ===== MediaRemote Decls (Private) =====

// 私有框架：MediaRemote.framework
extern void MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t queue);
extern void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, void (^completion)(CFDictionaryRef info));

static NSString * const CSNowPlayingDidUpdateNotification = @"CSNowPlayingDidUpdateNotification";

#pragma mark - ===== NowPlaying Center =====

@interface CSNowPlayingCenter : NSObject
@property (nonatomic, strong, readonly) NSDictionary *info;
+ (instancetype)shared;
- (void)start;
- (void)refresh;
@end

@interface CSNowPlayingCenter ()
@property (nonatomic, strong) NSDictionary *info;
@end

@implementation CSNowPlayingCenter

+ (instancetype)shared {
    static CSNowPlayingCenter *x;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        x = [CSNowPlayingCenter new];
    });
    return x;
}

- (void)start {
    MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_get_main_queue());

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSArray *names = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingPlaybackStateDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ];

    for (NSString *n in names) {
        [nc addObserverForName:n object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self refresh];
        }];
    }

    [self refresh];
}

- (void)refresh {
    MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef infoRef) {
        self.info = infoRef ? (__bridge NSDictionary *)infoRef : @{};
        [[NSNotificationCenter defaultCenter] postNotificationName:CSNowPlayingDidUpdateNotification object:nil];
    });
}

@end

#pragma mark - ===== Animated Background (Gradient + Particles) =====

@interface CSAnimatedBackgroundView : UIView
- (void)start;
- (void)stop;
- (void)reloadPrefsAndApply; // 热更新
@end

@implementation CSAnimatedBackgroundView {
    CAGradientLayer *_grad;
    CAEmitterLayer *_emitter;
    BOOL _running;
}

+ (UIImage *)cs_makeDotImage:(CGFloat)size {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint center = CGPointMake(size/2.0, size/2.0);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[
        (id)[UIColor colorWithWhite:1 alpha:0.9].CGColor,
        (id)[UIColor colorWithWhite:1 alpha:0.0].CGColor
    ];
    CGFloat locs[] = {0.0, 1.0};
    CGGradientRef g = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locs);

    CGContextDrawRadialGradient(ctx, g,
                                center, 0,
                                center, size/2.0,
                                kCGGradientDrawsAfterEndLocation);

    CGGradientRelease(g);
    CGColorSpaceRelease(cs);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;

        // 渐变层
        _grad = [CAGradientLayer layer];
        _grad.frame = self.bounds;
        _grad.startPoint = CGPointMake(0, 0);
        _grad.endPoint   = CGPointMake(1, 1);
        _grad.colors = @[
            (id)[UIColor colorWithRed:0.10 green:0.10 blue:0.10 alpha:0.45].CGColor,
            (id)[UIColor colorWithRed:0.20 green:0.20 blue:0.20 alpha:0.20].CGColor,
            (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.05 alpha:0.35].CGColor
        ];
        _grad.locations = @[@0.0, @0.55, @1.0];
        [self.layer addSublayer:_grad];

        // 粒子层
        _emitter = [CAEmitterLayer layer];
        _emitter.emitterShape = kCAEmitterLayerRectangle;
        _emitter.emitterMode  = kCAEmitterLayerSurface;
        _emitter.renderMode   = kCAEmitterLayerAdditive;
        _emitter.birthRate    = 0.0; // start 时再开
        [self.layer addSublayer:_emitter];

        CAEmitterCell *c = [CAEmitterCell emitterCell];
        c.birthRate = 18;
        c.lifetime  = 3.5;
        c.velocity  = 18;
        c.velocityRange = 25;
        c.yAcceleration = -8;
        c.emissionRange = (float)M_PI;
        c.scale = 0.015;
        c.scaleRange = 0.02;
        c.alphaSpeed = -0.35;
        c.spin = 0.8;
        c.spinRange = 1.2;
        c.color = [UIColor colorWithWhite:1 alpha:0.25].CGColor;

        c.contents = (id)[[self.class cs_makeDotImage:18] CGImage];
        _emitter.emitterCells = @[c];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _grad.frame = self.bounds;
    _emitter.frame = self.bounds;
    _emitter.emitterPosition = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    _emitter.emitterSize = CGSizeMake(self.bounds.size.width, self.bounds.size.height);
}

- (void)applyGradientAnimationsIfNeeded {
    [_grad removeAllAnimations];

    BOOL enableGradient = CSBoolPref(@"enableGradient", YES);
    if (!enableGradient) return;

    CABasicAnimation *colors = [CABasicAnimation animationWithKeyPath:@"colors"];
    colors.duration = 6.0;
    colors.autoreverses = YES;
    colors.repeatCount = HUGE_VALF;
    colors.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    colors.toValue = @[
        (id)[UIColor colorWithRed:0.18 green:0.18 blue:0.18 alpha:0.55].CGColor,
        (id)[UIColor colorWithRed:0.05 green:0.05 blue:0.05 alpha:0.18].CGColor,
        (id)[UIColor colorWithRed:0.22 green:0.22 blue:0.22 alpha:0.40].CGColor
    ];
    [_grad addAnimation:colors forKey:@"cs_grad_colors"];

    CABasicAnimation *loc = [CABasicAnimation animationWithKeyPath:@"locations"];
    loc.duration = 5.5;
    loc.autoreverses = YES;
    loc.repeatCount = HUGE_VALF;
    loc.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    loc.toValue = @[@0.0, @0.35, @1.0];
    [_grad addAnimation:loc forKey:@"cs_grad_loc"];
}

- (void)applyEmitterPrefsIfNeeded {
    BOOL enableParticles = CSBoolPref(@"enableParticles", YES);
    double particleRate = CSDoublePref(@"particleRate", 18.0);     // 建议 10~25
    double particleScale = CSDoublePref(@"particleScale", 1.0);    // 1.0 默认
    double particleSpeed = CSDoublePref(@"particleSpeed", 1.0);    // 1.0 默认

    _emitter.birthRate = enableParticles ? 1.0 : 0.0;

    if (_emitter.emitterCells.count) {
        CAEmitterCell *c = _emitter.emitterCells.firstObject;
        c.birthRate = enableParticles ? (float)particleRate : 0.0;

        // 速度/大小做倍率调节（保守改动，稳定）
        c.scale = 0.015 * particleScale;
        c.scaleRange = 0.02 * particleScale;
        c.velocity = 18 * particleSpeed;
        c.velocityRange = 25 * particleSpeed;

        // 重要：有些系统上改 cell 需要“重新赋值 emitterCells”才生效
        _emitter.emitterCells = @[c];
    }
}

- (void)reloadPrefsAndApply {
    CSSyncPrefs();
    if (!_running) return;

    BOOL enabled = CSBoolPref(@"enabled", YES);
    if (!enabled) {
        [self stop];
        return;
    }

    [self applyGradientAnimationsIfNeeded];
    [self applyEmitterPrefsIfNeeded];
}

- (void)start {
    if (_running) return;
    _running = YES;

    BOOL enabled = CSBoolPref(@"enabled", YES);
    if (!enabled) {
        [self stop];
        return;
    }

    [self applyGradientAnimationsIfNeeded];
    [self applyEmitterPrefsIfNeeded];
}

- (void)stop {
    _running = NO;
    [_grad removeAllAnimations];
    _emitter.birthRate = 0.0;
}

@end

#pragma mark - ===== Mini Player View (B: 极简条形 + 歌词占位) =====

@interface CSMiniNowPlayingView : UIView
- (void)start;
- (void)stop;
- (void)reloadPrefs;
@end

@implementation CSMiniNowPlayingView {
    CSAnimatedBackgroundView *_bg;
    UILabel *_title;
    UILabel *_sub;
    UILabel *_lyric;

    UIProgressView *_progress;
    NSTimer *_timer;

    BOOL _running;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 14.0;
        self.clipsToBounds = YES;

        _bg = [[CSAnimatedBackgroundView alloc] initWithFrame:self.bounds];
        _bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_bg];

        _title = [UILabel new];
        _title.font = [UIFont boldSystemFontOfSize:14];
        _title.textColor = UIColor.whiteColor;
        _title.numberOfLines = 1;

        _sub = [UILabel new];
        _sub.font = [UIFont systemFontOfSize:12];
        _sub.textColor = [UIColor colorWithWhite:1 alpha:0.75];
        _sub.numberOfLines = 1;

        _lyric = [UILabel new];
        _lyric.font = [UIFont systemFontOfSize:13];
        _lyric.textColor = [UIColor colorWithWhite:1 alpha:0.90];
        _lyric.numberOfLines = 1;

        _progress = [UIProgressView new];
        _progress.progress = 0.0;

        [self addSubview:_title];
        [self addSubview:_sub];
        [self addSubview:_lyric];
        [self addSubview:_progress];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(updateUI)
                                                     name:CSNowPlayingDidUpdateNotification
                                                   object:nil];

        [self updateUI];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    _timer = nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat pad = 12;
    CGFloat w = self.bounds.size.width - pad*2;

    _title.frame = CGRectMake(pad, pad, w, 18);
    _sub.frame   = CGRectMake(pad, CGRectGetMaxY(_title.frame)+2, w, 16);
    _lyric.frame = CGRectMake(pad, CGRectGetMaxY(_sub.frame)+8, w, 18);
    _progress.frame = CGRectMake(pad, self.bounds.size.height - pad - 2, w, 2);
}

- (void)reloadPrefs {
    [_bg reloadPrefsAndApply];
}

- (void)start {
    if (_running) return;
    _running = YES;

    BOOL enabled = CSBoolPref(@"enabled", YES);
    if (!enabled) {
        [self stop];
        return;
    }

    [_bg start];

    // 低频刷新：用于进度兜底 / 后续歌词时间轴
    if (!_timer) {
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.8
                                                  target:self
                                                selector:@selector(updateUI)
                                                userInfo:nil
                                                 repeats:YES];
    }
    [self updateUI];
}

- (void)stop {
    _running = NO;
    [_bg stop];
    [_timer invalidate];
    _timer = nil;
}

- (void)updateUI {
    NSDictionary *info = [CSNowPlayingCenter shared].info ?: @{};
    // key 名不同 app/版本会有差异，这里做多重兜底
    NSString *title  = info[@"kMRMediaRemoteNowPlayingInfoTitle"]  ?: info[@"title"]  ?: @"未在播放";
    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: info[@"artist"] ?: @"";
    NSString *album  = info[@"kMRMediaRemoteNowPlayingInfoAlbum"]  ?: info[@"album"]  ?: @"";

    _title.text = title;

    if (artist.length && album.length) _sub.text = [NSString stringWithFormat:@"%@ · %@", artist, album];
    else if (artist.length) _sub.text = artist;
    else _sub.text = @"";

    // 歌词：先占位。后续你接“歌词提供器”时，把这行替换成实际歌词即可
    // 例如：_lyric.text = [[CSLyricCenter shared] currentLine] ?: @"";
    _lyric.text = CSBoolPref(@"showLyricPlaceholder", YES) ? @"♪ 这里显示歌词（后续可接跑马/逐字）" : @"";

    NSNumber *elapsed  = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    NSNumber *duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
    if (elapsed && duration && duration.doubleValue > 0) {
        _progress.progress = (float)(elapsed.doubleValue / duration.doubleValue);
    } else {
        _progress.progress = 0.0;
    }
}

@end

#pragma mark - ===== Inject / Replace (Display-layer only) =====

static const void *kCSInjectedKey = &kCSInjectedKey;
static const void *kCSMiniViewKey = &kCSMiniViewKey;

static UIView *CSFindMediaContainerView(UIView *root) {
    for (UIView *v in root.subviews) {
        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"MediaControls"] || [cn containsString:@"NowPlaying"] || [cn containsString:@"MRU"]) {
            return v;
        }
        UIView *hit = CSFindMediaContainerView(v);
        if (hit) return hit;
    }
    return nil;
}

static void CSHideOriginalSubviews(UIView *container) {
    // 注意：我们只在“注入前”隐藏原生子视图
    // 保留原生逻辑链，不 remove，降低崩溃风险
    for (UIView *sub in container.subviews) {
        sub.alpha = 0.0;
        sub.userInteractionEnabled = NO;
    }
}

static void CSInjectMiniPlayer(UIViewController *vc) {
    if (!vc.view) return;
    if (!CSBoolPref(@"enabled", YES)) return;

    // 已经注入过：只确保 start + prefs 生效
    CSMiniNowPlayingView *mini = (CSMiniNowPlayingView *)objc_getAssociatedObject(vc, kCSMiniViewKey);
    if (mini) {
        [mini reloadPrefs];
        [mini start];
        return;
    }

    UIView *container = CSFindMediaContainerView(vc.view);
    if (!container) return;

    objc_setAssociatedObject(vc, kCSInjectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CSHideOriginalSubviews(container);

    CGRect f = CGRectInset(container.bounds, 8, 8);
    mini = [[CSMiniNowPlayingView alloc] initWithFrame:f];
    mini.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:mini];

    objc_setAssociatedObject(vc, kCSMiniViewKey, mini, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [mini start];
}

static void CSStopMiniPlayer(UIViewController *vc) {
    CSMiniNowPlayingView *mini = (CSMiniNowPlayingView *)objc_getAssociatedObject(vc, kCSMiniViewKey);
    if (mini) {
        [mini stop];
        [mini removeFromSuperview];
        objc_setAssociatedObject(vc, kCSMiniViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, kCSInjectedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - ===== Prefs Changed Handler =====

static void CSPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // 只同步一下，具体应用在下一次 start / reloadPrefsAndApply 中完成
    CSSyncPrefs();
}

#pragma mark - ===== Hooks =====

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    // 先用类名做“粗过滤”，减少递归遍历次数
    NSString *cn = NSStringFromClass([self class]);
    if ([cn containsString:@"ControlCenter"] || [cn containsString:@"CCUI"] || [cn containsString:@"MediaControls"]) {
        CSInjectMiniPlayer(self);
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;

    NSString *cn = NSStringFromClass([self class]);
    if ([cn containsString:@"ControlCenter"] || [cn containsString:@"CCUI"] || [cn containsString:@"MediaControls"]) {
        CSStopMiniPlayer(self);
    }
}

%end

#pragma mark - ===== ctor =====

%ctor {
    @autoreleasepool {
        // 1) 载入 MediaRemote
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);

        // 2) 启动 Now Playing 监听
        [[CSNowPlayingCenter shared] start];

        // 3) prefs 热更新 Darwin 通知
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        CSPrefsChanged,
                                        (__bridge CFStringRef)kCSPrefsChangedDarwin,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        // 4) 启动先同步一次
        CSSyncPrefs();
    }
}
