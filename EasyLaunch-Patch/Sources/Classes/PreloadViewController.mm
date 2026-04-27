#import "PreloadViewController.h"
#import "EasyLaunchConfig.h"
#import "PLServicesWrapper.h"        // Firebase + AppsFlyer bridge (.m, pure ObjC)
#import <UserNotifications/UserNotifications.h>
#import "NotificationPromptViewController.h"
#import <TargetConditionals.h>

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Персистентный наблюдатель FCM-токена
// ─────────────────────────────────────────────────────────────────────────────

/// Храним наблюдатель сильной ссылкой — живёт всё время жизни приложения.
static id        s_fcmTokenObserver  = nil;
/// URL эндпойнта, известный наблюдателю (не зависит от жизни VC).
static NSString *s_fcmEndpointURL   = nil;

/// Отправляет на сервер поля Firebase + данные конверсии AF.
/// Вызывается из блока наблюдателя (без ссылки на VC).
static void PL_sendFirebaseFields(NSString *endpointURL)
{
    NSString *pushToken       = [PLServicesWrapper firebasePushToken];
    if (pushToken.length == 0) return; // токен ещё недоступен

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"bundle_id"]   = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    body[@"platform"]    = @"ios";
    body[@"os"]          = @"iOS";

    NSString *afId = [PLServicesWrapper appsFlyerDeviceId];
    if (afId.length)  body[@"af_id"] = afId;

    body[@"locale"] = [NSLocale preferredLanguages].firstObject ?: @"en";

    NSString *firebaseProject = [PLServicesWrapper firebaseProjectId];
    if (firebaseProject.length) body[@"firebase_project_id"] = firebaseProject;
    body[@"push_token"] = pushToken;

    // Данные конверсии AF (сохраняются персистентно)
    NSDictionary *afData = [PLServicesWrapper storedAppsFlyerConversionData];
    if (afData.count) [body addEntriesFromDictionary:afData];

    NSError *jsonErr = nil;
    NSData  *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (!jsonData) { NSLog(@"[PreloadVC] FCM-send JSON error: %@", jsonErr); return; }

    NSURL *url = [NSURL URLWithString:[endpointURL stringByAppendingString:@"/config.php"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10.0;
    req.HTTPBody = jsonData;

    // Ответ сервера не важен
    [[NSURLSession.sharedSession dataTaskWithRequest:req
                                  completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)r;
        NSLog(@"[PreloadVC] FCM-send: status=%ld error=%@", (long)http.statusCode, e);
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PreloadConfig
// ─────────────────────────────────────────────────────────────────────────────

@implementation PreloadConfig

- (instancetype)init
{
    self = [super init];
    if (self) {
        _appsflyerTimeout = 15.0;
        _endpointTimeout  = 10.0;
    }
    return self;
}

+ (instancetype)configWithAppsDevKey:(NSString *)devKey
                          appleAppId:(NSString *)appleId
                         endpointURL:(NSString *)endpoint
{
    PreloadConfig *c      = [PreloadConfig new];
    c.appsDevKey          = devKey;
    c.appleAppId          = appleId;
    c.endpointURL         = endpoint;
    return c;
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PreloadViewController private interface
// ─────────────────────────────────────────────────────────────────────────────

@interface PreloadViewController ()

/// Фоновое изображение
@property (nonatomic, strong) UIImageView              *backgroundImageView;

/// Логотип приложения
@property (nonatomic, strong) UIImageView              *logoImageView;

/// Спиннер — крутится всё время загрузки
@property (nonatomic, strong) UIActivityIndicatorView  *spinner;

/// Собранные данные атрибуции для передачи на эндпоинт
@property (nonatomic, strong, nullable) NSDictionary *attributionData;
// Guard to avoid presenting the custom notification prompt multiple times within the same call
@property (atomic, assign) BOOL isPresentingNotificationPrompt;
// Флаг сессии: уведомления уже спрашивались в рамках текущего запуска приложения (in-memory, не персистируется)
@property (atomic, assign) BOOL notificationPromptShownThisSession;
// Prevent repeated endpoint refresh attempts during a single preload run
@property (atomic, assign) BOOL endpointRefreshAttempted;
/// Используется для отображения ошибки подключения без presentViewController
@property (nonatomic, strong) UIView *noInternetView;

/// Разбор JSON ответа config.php (разные имена полей у бекендов).
- (nullable NSURL *)pl_configRedirectURLFromJSONDictionary:(NSDictionary *)dict;

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation PreloadViewController

// ── Lifecycle ──────────────────────────────────────────────────────────────────

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self pl_setupBackground];
    [self pl_setupLogoAndSpinner];
    [self pl_setupNoInternetView];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    _backgroundImageView.frame = self.view.bounds;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self startChecks];
}

// ── Public ─────────────────────────────────────────────────────────────────────

- (void)startChecks
{
    self.attributionData = nil;
    self.noInternetView.hidden = YES;
    [_spinner startAnimating];

    // ── Push-путь: приложение открыто тапом по уведомлению с URL ──────────────
    if (self.pendingPushURL) {
        NSURL *pushURL = self.pendingPushURL;
        self.pendingPushURL = nil; // Сбрасываем после обработки
        NSLog(@"[PreloadVC] Using push URL: %@", pushURL);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onOpenURL) self.onOpenURL(pushURL);
            [self->_spinner stopAnimating];
        });
        return;
    }

    // Убедимся, что цепочка запуска не выполняется при наличии URL из пуша
    NSLog(@"[PreloadVC] No pending push URL, proceeding with config chain");

    // ── Всегда выполняем полную цепочку, чтобы дать серверу шанс переключить
    //     режим (например, если AppsFlyer-атрибуция non-organic пришла позже
    //     первого запуска и сервер теперь хочет открыть WebView вместо Unity).
    //     PLLaunchMode/PLLastEndpointURLString используются только как fallback
    //     внутри цепочки, не как fast-path до сервера.
    NSString *savedMode = [[NSUserDefaults standardUserDefaults] stringForKey:@"PLLaunchMode"];
    if (savedMode) {
        NSLog(@"[PreloadVC] Saved launch mode: %@ — running full chain anyway (server decides)", savedMode);
    }

    [self pl_updateStatus:@"Starting…" detail:nil progress:0.0];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self pl_step1_checkNetwork];
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)pl_setupBackground
{
    _backgroundImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"LaunchBackground"]];
    _backgroundImageView.frame = self.view.bounds;
    _backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    _backgroundImageView.clipsToBounds = YES;
    [self.view insertSubview:_backgroundImageView atIndex:0];
}

- (void)pl_setupLogoAndSpinner
{
    UIView *v = self.view;

    // Логотип
    _logoImageView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"AppLogo"]];
    _logoImageView.contentMode = UIViewContentModeScaleAspectFit;
    _logoImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_logoImageView];

    // Спиннер
    _spinner = [[UIActivityIndicatorView alloc]
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    _spinner.color = [UIColor whiteColor];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:_spinner];
    [_spinner startAnimating];

    // Desired width — 55 % of view width (high priority, can yield).
    NSLayoutConstraint *logoWidthDesired =
        [_logoImageView.widthAnchor constraintEqualToAnchor:v.widthAnchor multiplier:0.55];
    logoWidthDesired.priority = UILayoutPriorityDefaultHigh; // 750

    // Hard caps so the logo never overflows in landscape.
    NSLayoutConstraint *logoWidthMax =
        [_logoImageView.widthAnchor constraintLessThanOrEqualToAnchor:v.widthAnchor multiplier:0.55];
    NSLayoutConstraint *logoHeightMax =
        [_logoImageView.heightAnchor constraintLessThanOrEqualToAnchor:v.safeAreaLayoutGuide.heightAnchor
                                                             multiplier:0.40];

    // Логотип — центр по Y на ~25% высоты экрана (1/4 сверху).
    // NSLayoutAttributeBottom view = высота экрана; multiplier 0.25 ставит centerY
    // ровно на четверти. Безопасная зона учтена hard-cap'ом по высоте ниже.
    NSLayoutConstraint *logoCenterY =
        [NSLayoutConstraint constraintWithItem:_logoImageView
                                     attribute:NSLayoutAttributeCenterY
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:v
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:0.25
                                      constant:0];

    [NSLayoutConstraint activateConstraints:@[
        [_logoImageView.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        logoCenterY,
        logoWidthDesired,
        logoWidthMax,
        logoHeightMax,
        // 1 : 1 — картинка квадратная
        [_logoImageView.heightAnchor constraintEqualToAnchor:_logoImageView.widthAnchor],

        // Спиннер — ниже логотипа
        [_spinner.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [_spinner.topAnchor     constraintEqualToAnchor:_logoImageView.bottomAnchor constant:24],
    ]];
}

- (void)pl_setupNoInternetView
{
    // Тёмно-серая «карточка» со скруглёнными углами — фон под текстом/кнопкой.
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.hidden = YES;
    container.backgroundColor = [UIColor colorWithWhite:0.13 alpha:0.92];
    container.layer.cornerRadius = 20;
    container.layer.masksToBounds = YES;
    [self.view addSubview:container];

    // Внутренний контейнер для контента — чтобы pad'ить сразу всё содержимое.
    UIView *content = [[UIView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:content];

    UIImageView *iconView = [[UIImageView alloc] init];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:52 weight:UIImageSymbolWeightLight];
        iconView.image = [UIImage systemImageNamed:@"wifi.slash" withConfiguration:cfg];
    }
    iconView.tintColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:iconView];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"No Internet Connection";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:20];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:titleLabel];

    UILabel *messageLabel = [[UILabel alloc] init];
    messageLabel.text = @"Please check your network settings\nand try again.";
    messageLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    messageLabel.font = [UIFont systemFontOfSize:15];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;
    messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:messageLabel];

    UIButton *retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [retryButton setTitle:@"Retry" forState:UIControlStateNormal];
    retryButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [retryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    retryButton.backgroundColor = [UIColor colorWithRed:0.20 green:0.48 blue:1.0 alpha:1.0];
    retryButton.layer.cornerRadius = 14;
    retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [retryButton addTarget:self
                    action:@selector(pl_retryButtonTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:retryButton];

    // Padding: 28pt по горизонтали, 32pt по вертикали внутри карточки.
    const CGFloat hPad = 28.0;
    const CGFloat vPad = 32.0;

    [NSLayoutConstraint activateConstraints:@[
        // Карточка центрирована, с боковыми отступами от краёв экрана.
        [container.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [container.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [container.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [container.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],

        // Контент с padding'ом внутри карточки.
        [content.topAnchor      constraintEqualToAnchor:container.topAnchor      constant:vPad],
        [content.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor   constant:-vPad],
        [content.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor  constant:hPad],
        [content.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-hPad],

        [iconView.topAnchor constraintEqualToAnchor:content.topAnchor],
        [iconView.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [iconView.heightAnchor constraintEqualToConstant:56],

        [titleLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [messageLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
        [messageLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [messageLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [retryButton.topAnchor constraintEqualToAnchor:messageLabel.bottomAnchor constant:28],
        [retryButton.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [retryButton.widthAnchor constraintEqualToConstant:200],
        [retryButton.heightAnchor constraintEqualToConstant:52],
        [retryButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];

    self.noInternetView = container;
}

- (void)pl_retryButtonTapped
{
    [self startChecks];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Этапы загрузки
// ─────────────────────────────────────────────────────────────────────────────
//
//   ┌─ Step 1 ──── Проверка сети              (0.00 → 0.15)
//   ├─ Step 2 ──── Инициализация Firebase      (0.15 → 0.40)
//   ├─ Step 3 ──── AppsFlyerr init + GCD wait  (0.40 → 0.70)
//   └─ Step 4 ──── Запрос к эндпоинту          (0.70 → 1.00)
//                   → onComplete  (Unity)
//                   → onOpenURL   (WebView)
//

// ── Step 1 : Сеть ─────────────────────────────────────────────────────────────

- (void)pl_step1_checkNetwork
{
    [self pl_updateStatus:@"Checking connection…"
                   detail:@"Network"
                 progress:0.05];

    NSString *pingTarget = self.config.endpointURL ?: @"https://apple.com";
    NSURL *pingURL = [NSURL URLWithString:pingTarget];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:pingURL
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:5.0];
    req.HTTPMethod = @"HEAD";

    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (e == nil) {
            [strongSelf pl_updateStatus:@"Connection OK" detail:nil progress:0.15];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [strongSelf pl_step2_initFirebase];
            });
            return;
        }

        NSLog(@"[PreloadVC] Network check to %@ failed: %@", pingTarget, e);

        // If the configured endpoint is down (or blocked by ATS), try a known reliable host
        // before showing the "No Internet" UI. This avoids false negatives when only the
        // endpoint is unreachable.
        if (![pingTarget.lowercaseString containsString:@"apple.com"]) {
            NSURL *fallbackURL = [NSURL URLWithString:@"https://apple.com"];
            NSMutableURLRequest *fallbackReq = [NSMutableURLRequest requestWithURL:fallbackURL
                                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                                   timeoutInterval:5.0];
            fallbackReq.HTTPMethod = @"HEAD";

            [[[NSURLSession sharedSession] dataTaskWithRequest:fallbackReq
                                            completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                if (e2 == nil) {
                    NSLog(@"[PreloadVC] Fallback network check OK (apple.com)");
                    [strongSelf2 pl_updateStatus:@"Connection OK" detail:@"Endpoint unreachable" progress:0.15];
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [strongSelf2 pl_step2_initFirebase];
                    });
                } else {
                    NSLog(@"[PreloadVC] Fallback network check failed: %@", e2);
                    [strongSelf2 pl_showNoInternetRetry];
                }
            }] resume];
        } else {
            [strongSelf pl_showNoInternetRetry];
        }
    }] resume];
}

// ── Step 2 : Firebase ─────────────────────────────────────────────────────────

- (void)pl_step2_initFirebase
{
    [self pl_updateStatus:@"Initializing Firebase…"
                   detail:@"Firebase"
                 progress:0.20];
    // Инициализируем Firebase напрямую — уведомления спрашиваем позже, только при WebView
    [PLServicesWrapper configureFirebase:^(NSError *fbError) {
        if (fbError) {
            NSLog(@"[PreloadVC] Firebase warning (non-fatal): %@", fbError.localizedDescription);
            [self pl_updateStatus:@"Firebase unavailable" detail:fbError.localizedDescription progress:0.40];
        } else {
            [self pl_updateStatus:@"Firebase ready" detail:nil progress:0.40];
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self pl_step3_initAppsFlyer];
        });
        // Регистрируем наблюдатель после Firebase init — к этому моменту
        // FIRMessaging.delegate уже выставлен и токен может прийти в любой момент.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self pl_registerPersistentFCMTokenObserver];
        });
    }];
}

/// Регистрирует глобальный наблюдатель PLFCMTokenDidUpdateNotification.
/// Вызывать один раз — наблюдатель хранится статически (s_fcmTokenObserver) и не удаляется.
- (void)pl_registerPersistentFCMTokenObserver
{
    NSString *endpoint = self.config.endpointURL;
    if (endpoint.length == 0) return;

    // Обновляем сохранённый URL (может измениться между запусками)
    s_fcmEndpointURL = [endpoint copy];

    if (s_fcmTokenObserver) return; // уже зарегистрирован

    s_fcmTokenObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:PLFCMTokenDidUpdateNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
            NSString *ep = s_fcmEndpointURL;
            if (!ep.length) return;
            NSLog(@"[PreloadVC] FCM token update — sending firebase fields to server");
            PL_sendFirebaseFields(ep);
        }];
}


// Показывает запрос уведомлений если:
//   1. Пользователь ещё не ответил на этот вопрос в ТЕКУЩЕЙ сессии (notificationPromptShownThisSession == NO)
//   2. Статус системы — NotDetermined или Denied (с учётом 3-дневного кулдауна)
// После завершения (в любую сторону) вызывает completion на главном потоке.
- (void)pl_checkAndAskNotificationsIfNeededWithCompletion:(void(^)(void))completion
{
    if (!completion) completion = ^{};

    // Если в эту сессию уже спрашивали — пропускаем
    if (self.notificationPromptShownThisSession) {
        NSLog(@"[PreloadVC] Notification prompt already shown this session — skipping");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
        return;
    }

    if (@available(iOS 10.0, *)) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
            UNAuthorizationStatus currentStatus = settings.authorizationStatus;
            BOOL shouldRequest = NO;
            if (currentStatus == UNAuthorizationStatusNotDetermined ||
                currentStatus == UNAuthorizationStatusDenied) {
                NSDate *lastDenied = [[NSUserDefaults standardUserDefaults] objectForKey:@"PLLastNotificationDeniedAt"];
                if (!lastDenied) {
                    shouldRequest = YES;
                } else {
                    NSTimeInterval since = [[NSDate date] timeIntervalSinceDate:lastDenied];
                    shouldRequest = (since >= (3 * 24 * 60 * 60)); // 3 дня
                }
            }

            if (!shouldRequest) {
                // Системное разрешение уже есть или кулдаун не истёк — помечаем сессию и продолжаем
                self.notificationPromptShownThisSession = YES;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.isPresentingNotificationPrompt) {
                    completion();
                    return;
                }
                self.isPresentingNotificationPrompt = YES;

                __weak typeof(self) weakSelf = self;
                NotificationPromptViewController *np = [[NotificationPromptViewController alloc]
                    initWithTitle:@"Enable Notifications"
                    message:@"Would you like to receive important notifications about the app?"
                    backgroundImage:nil
                    allowHandler:^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
                        strongSelf.notificationPromptShownThisSession = YES;
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"PLAskedForNotifications"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        if (currentStatus == UNAuthorizationStatusDenied) {
                            // Системное разрешение уже отозвано — iOS не покажет диалог повторно
                            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"PLLastNotificationDeniedAt"];
                            [[NSUserDefaults standardUserDefaults] synchronize];
                            strongSelf.isPresentingNotificationPrompt = NO;
                            completion();
                        } else {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                UNAuthorizationOptions opts = (UNAuthorizationOptionBadge | UNAuthorizationOptionSound | UNAuthorizationOptionAlert);
                                [center requestAuthorizationWithOptions:opts completionHandler:^(BOOL granted, NSError * _Nullable err) {
                                    if (!granted) {
                                        [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"PLLastNotificationDeniedAt"];
                                    } else {
                                        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"PLLastNotificationDeniedAt"];
                                    }
                                    [[NSUserDefaults standardUserDefaults] synchronize];
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        strongSelf.isPresentingNotificationPrompt = NO;
                                        completion();
                                    });
                                }];
                            });
                        }
                    }
                    cancelHandler:^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
                        strongSelf.notificationPromptShownThisSession = YES;
                        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"PLAskedForNotifications"];
                        [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"PLLastNotificationDeniedAt"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        strongSelf.isPresentingNotificationPrompt = NO;
                        completion();
                    }];

                [self presentViewController:np animated:YES completion:nil];
            });
        }];
    } else {
        self.notificationPromptShownThisSession = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    }
}

// ── Step 3 : AppsFlyer ───────────────────────────────────────────────────────

- (void)pl_step3_initAppsFlyer
{
    [self pl_updateStatus:@"Initializing AppsFlyer…"
                   detail:@"AppsFlyer"
                 progress:0.45];

    NSString *devKey   = self.config.appsDevKey ?: @"";
    NSString *appleId  = self.config.appleAppId ?: @"";
    NSTimeInterval tmo = self.config ? self.config.appsflyerTimeout : 15.0;

    // PLServicesWrapper — чистый ObjC, без проблем с C++ модулями
    [PLServicesWrapper startAppsFlyerWithDevKey:devKey
                                     appleAppId:appleId
                               gcdWaitTimeout:tmo
                                     completion:^(NSDictionary *attribution, NSError *error) {
        NSLog(@"[PreloadVC] AppsFlyer attribution: %@", attribution);
        self.attributionData = attribution;
        [self pl_updateStatus:@"AppsFlyer ready" detail:nil progress:0.70];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self pl_step4_requestEndpoint:attribution];
        });
    }];
}

// ── Step 4 : Запрос к эндпоинту (Release на устройстве: только реальные данные AF + тело POST) ──

- (nullable NSURL *)pl_configRedirectURLFromJSONDictionary:(NSDictionary *)dict
{
    if (![dict isKindOfClass:[NSDictionary class]] || dict.count == 0) return nil;

    id okFlag = dict[@"ok"];
    if (!okFlag) okFlag = dict[@"success"];

    BOOL hasExplicitOk = (okFlag != nil);
    BOOL serverOk = NO;
    if (okFlag) {
        if ([okFlag isKindOfClass:[NSNumber class]]) {
            serverOk = [(NSNumber *)okFlag boolValue];
        } else if ([okFlag isKindOfClass:[NSString class]]) {
            NSString *s = [(NSString *)okFlag lowercaseString];
            serverOk = [s isEqualToString:@"1"] || [s isEqualToString:@"true"] || [s isEqualToString:@"yes"];
        }
    }

    NSString *urlString = nil;
    if ([dict[@"url"] isKindOfClass:[NSString class]]) urlString = dict[@"url"];
    if (!urlString.length && [dict[@"link"] isKindOfClass:[NSString class]]) urlString = dict[@"link"];
    if (!urlString.length && [dict[@"redirect"] isKindOfClass:[NSString class]]) urlString = dict[@"redirect"];
    if (!urlString.length && [dict[@"webview_url"] isKindOfClass:[NSString class]]) urlString = dict[@"webview_url"];

    if (hasExplicitOk && !serverOk) return nil;
    if (!urlString.length) return nil;
    return [NSURL URLWithString:urlString];
}

- (void)pl_step4_requestEndpoint:(nullable NSDictionary *)attribution
{
    NSString *baseURL = self.config.endpointURL;
    if (baseURL.length == 0) {
        NSLog(@"[PreloadVC] endpointURL is empty — proceeding to Unity");
        [self pl_finishWithURL:nil];
        return;
    }

    [self pl_updateStatus:@"Verifying…"
                   detail:@"Server check"
                 progress:0.75];

    // ── Формируем тело запроса ────────────────────────────────────────────────
    NSMutableDictionary *body = [NSMutableDictionary dictionary];

    // Данные устройства
    body[@"bundle_id"]   = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    body[@"app_version"] = [[[NSBundle mainBundle] infoDictionary]
                            objectForKey:@"CFBundleShortVersionString"] ?: @"";
    body[@"platform"]    = @"ios";
    body[@"idfa"]        = [self pl_idfaString];

    // af_id — AppsFlyer Device ID (обязателен во всех запросах)
    NSString *afId = [PLServicesWrapper appsFlyerDeviceId];
    if (afId.length) body[@"af_id"] = afId;

    body[@"locale"] = [NSLocale preferredLanguages].firstObject ?: @"en";

    // Данные атрибуции AppsFlyerr
    // Передаём данные конверсии AppsFlyer без изменений, если они есть.
    // Приоритет: сначала сохранённые в PLServicesWrapper (persisted), затем текущие attribution.
    NSDictionary *storedAF = [PLServicesWrapper storedAppsFlyerConversionData];
    NSDictionary *afData = (storedAF && [storedAF isKindOfClass:[NSDictionary class]] && storedAF.count)
        ? storedAF
        : ((attribution && [attribution isKindOfClass:[NSDictionary class]] && attribution.count) ? attribution : nil);
    if (afData) {
        // addEntriesFromDictionary ломает POST: в данных AF бывают NSDate/NSNull/вложенные dict —
        // NSJSONSerialization падает → pl_finishWithURL(nil) → всегда Unity.
        [afData enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            if (![key isKindOfClass:[NSString class]]) return;
            if (obj == nil || obj == [NSNull null]) {
                body[key] = @"";
            } else if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) {
                body[key] = obj;
            } else if ([obj isKindOfClass:[NSDictionary class]] || [obj isKindOfClass:[NSArray class]]) {
                NSError *subErr = nil;
                NSData *sub = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&subErr];
                body[key] = sub ? [[NSString alloc] initWithData:sub encoding:NSUTF8StringEncoding] : @"{}";
            } else if ([obj isKindOfClass:[NSDate class]]) {
                body[key] = @((long)[(NSDate *)obj timeIntervalSince1970]).stringValue;
            } else {
                body[key] = [obj description] ?: @"";
            }
        }];
    }

    // Дополнительные обязательные поля
    body[@"os"] = @"iOS";
    // store_id берём из конфига (apple App Store id)
    body[@"store_id"] = self.config.appleAppId ?: @"";

    // Firebase fields: project id и push token (всегда включаем, пустая строка если недоступен)
    NSString *firebaseProject = [PLServicesWrapper firebaseProjectId];
    if (firebaseProject && firebaseProject.length) {
        body[@"firebase_project_id"] = firebaseProject;
    }
    NSString *pushToken = [PLServicesWrapper firebasePushToken];
    body[@"push_token"] = pushToken ?: @"";

#if TARGET_OS_SIMULATOR
    // Release-сборки Unity/Xcode часто без DEBUG=1 — поэтому только TARGET_OS_SIMULATOR.
    // Симулятор почти всегда даёт organic / пустую конверсию; подставляем типичные
    // поля non-organic + стабильный af_id (без него бэкенд может всегда отдавать «игру»).
    if (![body[@"af_id"] isKindOfClass:[NSString class]] || ![(NSString *)body[@"af_id"] length]) {
        body[@"af_id"] = @"SIMULATOR-TEST-AFID-00000000-0000-4000-8000-000000000001";
    }
    body[@"af_status"]       = @"Non-organic";
    body[@"media_source"]    = @"easylaunch_simulator";
    body[@"campaign"]        = @"debug_test";
    body[@"campaign_id"]     = @"debug_campaign_id";
    body[@"af_channel"]      = @"simulator";
    body[@"is_first_launch"] = @YES;
    NSLog(@"[PreloadVC] Simulator: synthetic non-organic AF fields merged into config.php body");
#endif

    // ── HTTP запрос ───────────────────────────────────────────────────────────
    NSURL *url = [NSURL URLWithString:[baseURL stringByAppendingString:@"/config.php"]];
#if TARGET_OS_SIMULATOR
    NSLog(@"[PreloadVC] Simulator → POST %@", url.absoluteString);
#endif
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSTimeInterval timeout = self.config ? self.config.endpointTimeout : 10.0;
    req.timeoutInterval = timeout;

    NSError *jsonErr = nil;
    NSData  *jsonData = [NSJSONSerialization dataWithJSONObject:body
                                                        options:0
                                                          error:&jsonErr];
    if (jsonErr || !jsonData) {
        NSLog(@"[PreloadVC] JSON serialization error: %@", jsonErr);
        [self pl_finishWithURL:nil];
        return;
    }
    req.HTTPBody = jsonData;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest  = timeout;
    cfg.timeoutIntervalForResource = timeout + 5;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error) {
            NSLog(@"[PreloadVC] Endpoint request error: %@", error);
            // Сетевая ошибка — показываем экран отсутствия интернета
            [self pl_showNoInternetRetry];
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSLog(@"[PreloadVC] Endpoint status: %ld", (long)http.statusCode);

        [self pl_updateStatus:@"Processing response…" detail:nil progress:0.90];

        // ── Разбираем ответ ───────────────────────────────────────────────────
        NSURL *redirectURL = nil;

        if (data.length) {
#if TARGET_OS_SIMULATOR
            NSString *rawPreview = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (rawPreview.length > 2048) rawPreview = [rawPreview substringToIndex:2048];
            NSLog(@"[PreloadVC] Simulator config.php response (preview): %@", rawPreview ?: @"(non-UTF8 body)");
#endif
            NSError *parseErr = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data
                                                     options:0
                                                       error:&parseErr];
            if (!parseErr && [json isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dict = (NSDictionary *)json;
                redirectURL = [self pl_configRedirectURLFromJSONDictionary:dict];

                id expires = dict[@"expires"];
                if (redirectURL && expires) {
                    NSLog(@"[PreloadVC] Endpoint expires: %@", expires);
                    double expiresTS = 0;
                    if ([expires isKindOfClass:[NSNumber class]]) {
                        expiresTS = [(NSNumber *)expires doubleValue];
                    } else if ([expires isKindOfClass:[NSString class]]) {
                        if (@available(iOS 10.0, *)) {
                            NSISO8601DateFormatter *fmt = [NSISO8601DateFormatter new];
                            NSDate *d = [fmt dateFromString:(NSString *)expires];
                            if (d) expiresTS = [d timeIntervalSince1970];
                        }
                        if (expiresTS == 0) {
                            expiresTS = [(NSString *)expires doubleValue];
                        }
                    }
                    if (expiresTS > 0) {
                        [[NSUserDefaults standardUserDefaults] setDouble:expiresTS forKey:@"PLLastEndpointExpires"];
                        [[NSUserDefaults standardUserDefaults] synchronize];
                        self.endpointRefreshAttempted = NO;
                    }
                }

                if (redirectURL) {
                    [[NSUserDefaults standardUserDefaults] setObject:redirectURL.absoluteString forKey:@"PLLastEndpointURLString"];
                    [[NSUserDefaults standardUserDefaults] synchronize];
                }
            } else {
                NSLog(@"[PreloadVC] Endpoint parse error: %@", parseErr);
            }
        }

        [self pl_finishWithURL:redirectURL];

    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Финал
// ─────────────────────────────────────────────────────────────────────────────

/// `url == nil`  → запускаем Unity (onComplete) — уведомления НЕ запрашиваем
/// `url != nil`  → показываем WebView (onOpenURL) — сначала запрашиваем уведомления (если не спрашивали в эту сессию)
- (void)pl_finishWithURL:(nullable NSURL *)url
{
    [self pl_updateStatus:@"Done!" detail:nil progress:1.00];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // ── Push-приоритет: проверяем на главном потоке после небольшой задержки. ──
        // pl_finishWithURL: вызывается из фонового потока (URLSession completion), поэтому
        // проверять pendingPushURL там небезопасно — didReceiveNotificationResponse: устанавливает
        // его через dispatch_async(main_queue) и этот блок может ещё не выполниться.
        // Проверка здесь, на main queue через 0.3с, гарантирует что пуш уже обработан.
        if (self.pendingPushURL) {
            NSURL *pushURL = self.pendingPushURL;
            self.pendingPushURL = nil;
            NSLog(@"[PreloadVC] Push URL received during chain — overriding server URL with: %@", pushURL);
            // Сохраняем режим запуска
            if (![[NSUserDefaults standardUserDefaults] stringForKey:@"PLLaunchMode"]) {
                [[NSUserDefaults standardUserDefaults] setObject:@"webview" forKey:@"PLLaunchMode"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
            [self->_spinner stopAnimating];
            [self pl_checkAndAskNotificationsIfNeededWithCompletion:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.onOpenURL) self.onOpenURL(pushURL);
                });
            }];
            return;
        }

        [self->_spinner stopAnimating];

        // Для WebView-пути: если config.php не вернул URL — используем последний сохранённый
        NSURL *useURL = url;
        if (!useURL) {
            NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:@"PLLastEndpointURLString"];
            if (stored.length) {
                useURL = [NSURL URLWithString:stored];
            }
        }

#if TARGET_OS_SIMULATOR
        if (!useURL) {
            NSString *fallback = PL_SIMULATOR_FALLBACK_WEBVIEW_URL;
            if ([fallback isKindOfClass:[NSString class]] && fallback.length > 0) {
                useURL = [NSURL URLWithString:fallback];
                NSLog(@"[PreloadVC] Simulator: using PL_SIMULATOR_FALLBACK_WEBVIEW_URL → %@", useURL);
            }
        }
#endif

        // ── Обновляем режим запуска по результату последнего ответа сервера ──
        // (раньше писалось только при первом запуске, из-за чего «unity» залипал
        //  даже после того как сервер начал возвращать URL — non-organic не открывал WebView).
        NSString *mode = useURL ? @"webview" : @"unity";
        NSString *currentMode = [[NSUserDefaults standardUserDefaults] stringForKey:@"PLLaunchMode"];
        if (![currentMode isEqualToString:mode]) {
            [[NSUserDefaults standardUserDefaults] setObject:mode forKey:@"PLLaunchMode"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            NSLog(@"[PreloadVC] Launch mode updated: %@ → %@", currentMode ?: @"(nil)", mode);
        }

        if (useURL) {
            // ── WebView path: сначала спрашиваем разрешение на уведомления, затем открываем ──
            NSLog(@"[PreloadVC] WebView path — checking notification permission before opening URL");
            [self pl_checkAndAskNotificationsIfNeededWithCompletion:^{
                NSLog(@"[PreloadVC] → opening URL: %@", useURL);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.onOpenURL) {
                        self.onOpenURL(useURL);
                    } else {
                        [[UIApplication sharedApplication] openURL:useURL
                                                           options:@{}
                                                 completionHandler:nil];
                    }
                });
            }];
        } else {
            // ── Unity path: уведомления не запрашиваем ──
            NSLog(@"[PreloadVC] → proceeding to Unity (no notification prompt)");
            if (self.onComplete) self.onComplete();
        }
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────────────

- (void)pl_updateStatus:(NSString *)text
                 detail:(nullable NSString *)detail
               progress:(float)progress
{
    // Визуальные индикаторы статуса/прогресса убраны — только спиннер остаётся
}

- (void)pl_showNoInternetRetry
{
    // Если режим уже определён как webview и есть сохранённый URL —
    // используем его как fallback вместо показа диалога «Нет интернета».
    NSString *savedMode = [[NSUserDefaults standardUserDefaults] stringForKey:@"PLLaunchMode"];
    if ([savedMode isEqualToString:@"webview"]) {
        NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:@"PLLastEndpointURLString"];
        NSURL *storedURL = stored.length ? [NSURL URLWithString:stored] : nil;
        if (storedURL) {
            NSLog(@"[PreloadVC] No internet — using stored WebView URL as fallback: %@", storedURL);
            [self pl_checkAndAskNotificationsIfNeededWithCompletion:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_spinner stopAnimating];
                    if (self.onOpenURL) {
                        self.onOpenURL(storedURL);
                    } else {
                        [[UIApplication sharedApplication] openURL:storedURL options:@{} completionHandler:nil];
                    }
                });
            }];
            return;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self pl_updateStatus:@"No connection" detail:nil progress:0.0];
        [self->_spinner stopAnimating];
        self.noInternetView.hidden = NO;
    });
}

/// Возвращает IDFA если доступен, иначе пустую строку.
/// Для iOS 14+ требует ATTrackingManager (раскомментируйте import).
- (NSString *)pl_idfaString
{
    // Раскомментируйте если подключён ATTrackingManager:
    //
    // #import <AppTrackingTransparency/AppTrackingTransparency.h>
    // #import <AdSupport/AdSupport.h>
    // if (@available(iOS 14, *)) {
    //     if ([ATTrackingManager trackingAuthorizationStatus]
    //             == ATTrackingManagerAuthorizationStatusAuthorized) {
    //         return [[[ASIdentifierManager sharedManager] advertisingIdentifier]
    //                 UUIDString];
    //     }
    // }
    return @"";
}

// ── Status bar ────────────────────────────────────────────────────────────────
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

// ── Orientation ──────────────────────────────────────────────────────────────
// PreloadVC поддерживает все ориентации — фактический выбор делает
// CustomAppController.application:supportedInterfaceOrientationsForWindow:.
- (BOOL)shouldAutorotate { return YES; }

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskAll;
}

@end
