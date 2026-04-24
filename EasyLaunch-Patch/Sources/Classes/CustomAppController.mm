#import "CustomAppController.h"
#import "PreloadViewController.h"
#import "WebViewController.h"
#import "WebViewConfig.h"
#import "EasyLaunchConfig.h"
#import "ScreenCaptureBlocker.h"
#import <UserNotifications/UserNotifications.h>

@interface UnityAppController (EasyLaunchForwardDecl)
- (void)initUnityWithScene:(UIWindowScene *)scene;
@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Private interface
// ─────────────────────────────────────────────────────────────────────────────

@interface CustomAppController () <UNUserNotificationCenterDelegate>

/// Временное окно с экраном загрузки
@property (nonatomic, strong, nullable) UIWindow *preloadWindow;

/// Сцена, полученная при первом вызове initUnityWithScene: — сохраняем для
/// передачи в super после завершения проверок
@property (nonatomic, weak, nullable) UIWindowScene *pendingScene;

/// Флаг: preload уже запущен и ждём завершения проверок
@property (nonatomic, assign) BOOL preloadInProgress;

/// URL из push-уведомления, по которому открылось приложение
@property (nonatomic, strong, nullable) NSURL *pendingPushURL;

@end

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Implementation
// ─────────────────────────────────────────────────────────────────────────────

@implementation CustomAppController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Class registration (fail-safe for patch_main_mm.py)
// ─────────────────────────────────────────────────────────────────────────────
//
// Подменяем AppControllerClassName прямо в рантайме при загрузке класса.
// Это дублирует работу patch_main_mm.py и страхует от ситуации, когда
// регулярка в скрипте не находит строку (например, другой формат main.mm в
// новых версиях Unity) — тогда бинарник соберётся с "UnityAppController" и
// preload-экран никогда не покажется.
//
// +load вызывается до main(), а значит до UIApplicationMain — значение успеет
// перезаписаться прежде чем UIKit прочитает AppControllerClassName.

+ (void)load
{
    extern const char *AppControllerClassName;
    AppControllerClassName = "CustomAppController";
    NSLog(@"[CustomAppController] +load: AppControllerClassName overridden to CustomAppController");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Push URL helper
// ─────────────────────────────────────────────────────────────────────────────

/// Извлекает URL из payload push-уведомления.
/// Ищет поле "url" в: корне payload → data словаре → aps словаре.
+ (nullable NSURL *)pl_pushURLFromUserInfo:(NSDictionary *)userInfo
{
    if (!userInfo) return nil;

    // 1. Корень payload: userInfo["url"]
    NSString *urlStr = userInfo[@"url"];

    // 2. FCM data payload: userInfo["data"]["url"]
    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
        NSDictionary *data = userInfo[@"data"];
        if ([data isKindOfClass:[NSDictionary class]]) {
            urlStr = data[@"url"];
        }
    }

    // 3. APS словарь (нестандартное размещение): userInfo["aps"]["url"]
    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
        NSDictionary *aps = userInfo[@"aps"];
        if ([aps isKindOfClass:[NSDictionary class]]) {
            urlStr = aps[@"url"];
        }
    }

    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) return nil;
    if (![urlStr hasSuffix:@"/"]) urlStr = [urlStr stringByAppendingString:@"/"];
    return [NSURL URLWithString:urlStr];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (instancetype)init
{
    self = [super init];
    NSLog(@"[CustomAppController] -init (instance=%p)", self);
    return self;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    NSLog(@"[CustomAppController] application:didFinishLaunchingWithOptions: BEGIN (launchOptions keys=%@)",
          launchOptions.allKeys);

    // Извлекаем URL из cold-start push
    NSDictionary *remoteNotif = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
    if (remoteNotif) {
        self.pendingPushURL = [CustomAppController pl_pushURLFromUserInfo:remoteNotif];
        if (self.pendingPushURL) {
            NSLog(@"[CustomAppController] Cold-start push URL: %@", self.pendingPushURL);
        }
    }

    BOOL result = [super application:application didFinishLaunchingWithOptions:launchOptions];
    NSLog(@"[CustomAppController] [super didFinishLaunchingWithOptions] returned %d", (int)result);

    // Устанавливаем делегат ПОСЛЕ super — иначе Unity перезапишет его в своём
    // didFinishLaunchingWithOptions.
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;

    // ── Показываем preload сразу здесь, не дожидаясь initUnityWithScene: ──────
    //
    // В Unity 6 точка initUnityWithScene: может не вызываться или вызываться
    // слишком поздно (Unity успевает инициализироваться внутри super-вызова
    // didFinishLaunchingWithOptions:). Чтобы гарантированно перекрыть Unity
    // на старте, создаём preload-окно прямо сейчас с windowLevel выше
    // нормального — оно ляжет поверх любого UIWindow, созданного Unity.
    //
    // Unity при этом продолжает инициализироваться в фоне; когда цепочка
    // проверок завершится, мы просто скрываем preload-окно, и пользователь
    // видит уже готовый Unity-экран (или WebView, если сервер вернул URL).
    if (!self.preloadInProgress && self.preloadWindow == nil) {
        self.preloadInProgress = YES;
        UIWindowScene *scene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    scene = (UIWindowScene *)s;
                    break;
                }
            }
        }
        self.pendingScene = scene;
        NSLog(@"[CustomAppController] Showing preload from didFinishLaunching (scene=%@)", scene);
        [self showPreloadScreenForScene:scene];
    }

    // Защита от захвата экрана
    //[[ScreenCaptureBlocker sharedBlocker] startProtecting];

    NSLog(@"[CustomAppController] application:didFinishLaunchingWithOptions: END");
    return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UNUserNotificationCenterDelegate
// ─────────────────────────────────────────────────────────────────────────────

/// Тап по уведомлению когда приложение в фоне или foreground.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler
{
    NSDictionary *userInfo = response.notification.request.content.userInfo;
    NSURL *pushURL = [CustomAppController pl_pushURLFromUserInfo:userInfo];


    if (pushURL) {
        NSLog(@"[CustomAppController] Push tap URL: %@", pushURL);
        dispatch_async(dispatch_get_main_queue(), ^{
            PreloadViewController *preloadVC =
                (PreloadViewController *)self.preloadWindow.rootViewController;

            if ([preloadVC isKindOfClass:[PreloadViewController class]]
                && preloadVC.presentedViewController == nil) {
                // Preload-экран активен и ещё не открыл WebView:
                // передаём URL — startChecks или pl_finishWithURL его подхватят.
                // Покрывает cold start + случай когда launchOptions не содержал URL.
                preloadVC.pendingPushURL = pushURL;

            } else if (self.preloadInProgress && self.preloadWindow == nil) {
                // Preload запускается, но окно ещё не создано (очень ранний cold start):
                // сохраняем — showPreloadScreenForScene передаст в VC.
                self.pendingPushURL = pushURL;

            } else {
                // Приложение уже работает (Unity/WebView открыт) — открываем/заменяем сразу.
                [self pl_openURL:pushURL];
            }
        });
    }

    completionHandler();
}

/// Показывает уведомление даже когда приложение на переднем плане
/// (пользователь видит баннер — решает тапать или нет).
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    if (@available(iOS 14.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner |
                          UNNotificationPresentationOptionSound);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert |
                          UNNotificationPresentationOptionSound);
    }
}

/// Фоновое/foreground получение remote notification (data messages и notification messages).
/// Вызывается когда приложение запущено в фоне и получает push, а также при тапе
/// если приложение было в foreground.
- (void)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
    fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    NSLog(@"[CustomAppController] didReceiveRemoteNotification: %@", userInfo);
    // Тап по уведомлению обрабатывается через userNotificationCenter:didReceiveNotificationResponse:
    // Здесь обрабатываем только фоновые data-пуши (content-available)
    [super application:application
        didReceiveRemoteNotification:userInfo
        fetchCompletionHandler:completionHandler];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Open URL helper (app already running)
// ─────────────────────────────────────────────────────────────────────────────

- (void)pl_openURL:(NSURL *)url
{
    // Ищем topmost presented view controller и показываем WebView поверх.
    // Перебираем все windows чтобы найти активный ключевой — используем keyWindow.
    UIWindow *keyWin = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { keyWin = w; break; }
                }
                if (keyWin) break;
            }
        }
    }
    if (!keyWin) {
        keyWin = self.preloadWindow ?: self.window;
    }

    UIViewController *top = keyWin.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if (!top) return;

    // Если уже открыт WebViewController с этим же URL — не открываем повторно
    if ([top isKindOfClass:[WebViewController class]]) {
        NSLog(@"[CustomAppController] pl_openURL: replacing existing WebViewController with push URL");
        [top dismissViewControllerAnimated:NO completion:^{
            [self pl_openURL:url];
        }];
        return;
    }

    WebViewController *wvc = [[WebViewController alloc] initWithURL:url];
    wvc.modalPresentationStyle = UIModalPresentationFullScreen;
    if (@available(iOS 13.0, *)) {
        wvc.modalInPresentation = YES;
    }
    __weak __typeof(self) weakSelf = self;
    wvc.onClose = ^{
        [weakSelf dismissPreloadAndStartUnity];
    };
    [top presentViewController:wvc animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Unity entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Перехватываем точку входа Unity.
/// Preload запущен ещё в didFinishLaunchingWithOptions: — здесь нам остаётся
/// только пробросить вызов дальше, чтобы Unity нормально инициализировался
/// в фоне (preload-окно с высоким windowLevel перекрывает Unity до dismiss).
/// Также перепривязываем preload-окно к полученной UIWindowScene, если в
/// didFinishLaunching сцены ещё не было.
- (void)initUnityWithScene:(UIWindowScene *)scene
{
    NSLog(@"[CustomAppController] initUnityWithScene: %@ (engineLoadState=%ld, preloadInProgress=%d)",
          scene, (long)self.engineLoadState, (int)self.preloadInProgress);

    self.pendingScene = scene;

    // Если preload-окно было создано без сцены (fallback на UIScreen.mainScreen.bounds) —
    // пересоздаём его теперь уже привязанным к конкретной UIWindowScene, иначе
    // на iPad/multi-window окно может вести себя некорректно.
    if (self.preloadWindow != nil && self.preloadWindow.windowScene == nil && scene != nil) {
        NSLog(@"[CustomAppController] Re-attaching preload window to scene %@", scene);
        UIWindow *old = self.preloadWindow;
        PreloadViewController *vc = (PreloadViewController *)old.rootViewController;
        UIWindow *newWin = [[UIWindow alloc] initWithWindowScene:scene];
        newWin.backgroundColor = [UIColor blackColor];
        newWin.windowLevel = UIWindowLevelNormal + 10;
        newWin.rootViewController = vc;
        [newWin makeKeyAndVisible];
        old.hidden = YES;
        self.preloadWindow = newWin;
    }

    [super initUnityWithScene:scene];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Preload window
// ─────────────────────────────────────────────────────────────────────────────

- (void)showPreloadScreenForScene:(UIWindowScene *)scene
{
    NSLog(@"[CustomAppController] showPreloadScreenForScene: %@", scene);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[CustomAppController] showPreloadScreenForScene: creating window (main queue)");
        // Создаём отдельное UIWindow поверх всего
        UIWindow *preloadWindow;
        if (scene != nil) {
            preloadWindow = [[UIWindow alloc] initWithWindowScene:scene];
        } else {
            preloadWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        }
        // Ensure UI outside presented controllers/webview is black
        preloadWindow.backgroundColor = [UIColor blackColor];
        // Уровень окна: выше стандартного, но ниже системных алертов
        preloadWindow.windowLevel = UIWindowLevelNormal + 10;

        PreloadViewController *vc = [[PreloadViewController alloc] init];

        PreloadConfig *cfg = [PreloadConfig configWithAppsDevKey:EL_APPSFLYER_DEV_KEY
                                                      appleAppId:EL_APPLE_APP_ID
                                                     endpointURL:EL_ENDPOINT_URL];
        vc.config = cfg;

        // Если приложение открыто через push с URL — передаём его напрямую
        if (self.pendingPushURL) {
            vc.pendingPushURL = self.pendingPushURL;
            self.pendingPushURL = nil;
        }

        // По завершении всех проверок — скрываем preload и запускаем Unity
        __weak __typeof(self) weakSelf = self;
        vc.onComplete = ^{
            [weakSelf dismissPreloadAndStartUnity];
        };

        // Если сервер вернул URL — открыть во встроенном WebView
        vc.onOpenURL = ^(NSURL *url) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (url) {
                    WebViewController *wvc = [[WebViewController alloc] initWithURL:url];
                    __weak __typeof(self) weakSelf2 = weakSelf;
                    wvc.onClose = ^{
                        [weakSelf2 dismissPreloadAndStartUnity];
                    };
                    // Present the WebViewController directly (no nav bar/header)
                    wvc.modalPresentationStyle = UIModalPresentationFullScreen;
                    if (@available(iOS 13.0, *)) {
                        wvc.modalInPresentation = YES;
                    }
                    [preloadWindow.rootViewController presentViewController:wvc animated:YES completion:nil];
                }
            });
        };

        preloadWindow.rootViewController = vc;
        [preloadWindow makeKeyAndVisible];
        self.preloadWindow = preloadWindow;
        NSLog(@"[CustomAppController] Preload window created: %@ (scene=%@, windowLevel=%.1f, rootVC=%@)",
              preloadWindow, preloadWindow.windowScene, preloadWindow.windowLevel, vc);
    });
}

- (void)dismissPreloadAndStartUnity
{
    NSLog(@"[CustomAppController] dismissPreloadAndStartUnity");
    // Гарантируем выполнение на главном потоке
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *preloadWindow = self.preloadWindow;

        // Плавное исчезновение preload-экрана.
        // Unity к этому моменту уже инициализирован через super-вызов
        // didFinishLaunchingWithOptions: / initUnityWithScene:, поэтому под
        // preload-окном уже отрисован Unity-view. Просто прячем preload.
        [UIView animateWithDuration:0.4
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            preloadWindow.alpha = 0.0;
        }
                         completion:^(BOOL finished) {
            preloadWindow.hidden = YES;
            self.preloadWindow = nil;
            self.preloadInProgress = NO;
            NSLog(@"[CustomAppController] Preload dismissed, Unity is now visible");
        }];
    });
}

/// Переустанавливаем себя как делегат нотификаций после каждого выхода на передний план —
/// Firebase и Unity могут перезаписывать delegate во время работы приложения.
- (void)applicationDidBecomeActive:(UIApplication *)application
{
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [super applicationDidBecomeActive:application];
}

@end
