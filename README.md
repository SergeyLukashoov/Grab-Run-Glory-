<p align="center">
  <img width="128" height="128" alt="ChatGPT Image Apr 15, 2026 at 04_16_02 PM" src="https://github.com/user-attachments/assets/7878f595-967d-4452-a8c4-c08d062efe3e" />
</p>

1. Форкните/скопируйте себе репозиторий
2. секреты <img width="819" height="555" alt="image" src="https://github.com/user-attachments/assets/e5fdfb49-b7be-4301-b1be-bfbae54ee3ec" />
3. переменные среды <img width="841" height="561" alt="image" src="https://github.com/user-attachments/assets/6e062b6f-dfd2-49bb-9ea0-b570e024e0a2" />
4. для задников на загрузке заменить png в EasyLaunch-Patch
5. Для фаербейса заменить файл в корне репозитория
6. Для пушей создавать профайл заканчивающийся на .NotificationService


## Общее описание

Патч перехватывает стандартный запуск Unity-приложения и вставляет между `application:didFinishLaunching` и инициализацией движка промежуточный экран загрузки. По результату сервера принимается решение: показать Unity или полноэкранный WKWebView.

**Компоненты:**

| Файл                                                                                                                                                                       | Роль                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [CustomAppController](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html)              | Подкласс[UnityAppController](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html), перехватывает `initUnityWithScene:` |
| [PreloadViewController](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html)            | Экран загрузки, запускает 4-шаговую цепочку проверок                                                                                                                                     |
| [PLServicesWrapper](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html)                | ObjC-мост к Firebase и AppsFlyer (чистый `.m` без C++)                                                                                                                                                              |
| [WebViewController](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html)                | Полноэкранный WKWebView с fallback через NSURLSession                                                                                                                                                             |
| [NotificationPromptViewController](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html) | Кастомный pre-permission экран уведомлений                                                                                                                                                                  |
| [NotificationService.swift](vscode-file://vscode-app/Applications/Visual%20Studio%20Code.app/Contents/Resources/app/out/vs/code/electron-browser/workbench/workbench.html)        | Notification Service Extension для rich-push                                                                                                                                                                                      |

## Порядок вызовов при запуске

```
application:didFinishLaunchingWithOptions:            ← CustomAppController
  ├─ извлекает pushURL из launchOptions (cold-start push)
  ├─ [super ...] → Unity начинает инициализацию
  └─ UNUserNotificationCenter.delegate = self  
↓ Unity вызывает
initUnityWithScene:           ← CustomAppController
  └─ showPreloadScreenForScene:
       └─ создаёт UIWindow(windowLevel = Normal+10)
          └─ PreloadViewController (rootViewController)
               └─ viewDidAppear → startChecks
startChecks
  ├─ [быстрый путь] pendingPushURL → onOpenURL(pushURL)
  ├─ [быстрый путь] PLLaunchMode=="unity" → 0.5s → onComplete
  └─ [полная цепочка]
       ↓
       pl_step1_checkNetwork  (HEAD endpointURL, таймаут 5с)
         ├─ fallback → HEAD apple.com
         └─ OK → pl_step2_initFirebase   

	pl_step2_initFirebase  (PLServicesWrapper configureFirebase:)
         ├─ регистрирует FCM-token observer (PL_sendFirebaseFields)
         └─ OK → pl_step3_initAppsFlyer

       pl_step3_initAppsFlyer  (GCD wait, таймаут 15с)
         └─ OK → pl_step4_requestEndpoint:

       pl_step4_requestEndpoint:  (POST endpointURL/config.php)
         └─ pl_finishWithURL:

    pl_finishWithURL:  (0.3с задержка, main queue)
         ├─ есть URL → pl_checkAndAskNotifications → onOpenURL(url)
         │     └─ WebViewController presentViewController fullscreen
         └─ нет URL → onComplete()
               └─ dismissPreloadAndStartUnity
                    └─ [super initUnityWithScene:pendingScene]
```
