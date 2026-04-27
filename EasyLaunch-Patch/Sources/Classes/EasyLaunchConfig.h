// EasyLaunchConfig.h
// ─────────────────────────────────────────────────────────────────────────────
// Центральная конфигурация EasyLaunch.
// Замените значения до применения патча, либо задайте переменные в
// easylaunch.config — patch.sh подставит их автоматически.
// ─────────────────────────────────────────────────────────────────────────────

#pragma once

// AppsFlyer Dev Key (из dashboard.appsflyer.com)
#define EL_APPSFLYER_DEV_KEY        @"YOUR_APPSFLYER_DEV_KEY"

// Apple App Store numeric ID (только цифры, без "id")
#define EL_APPLE_APP_ID             @"YOUR_APPLE_APP_ID"

// Базовый URL вашего сервера (без завершающего слэша).
// Эндпоинт запроса: EL_ENDPOINT_URL + "/config.php"
#define EL_ENDPOINT_URL             @"https://grab-run-glory.com"

// Заголовок на экране загрузки (название вашего приложения)
#define EL_LOADING_TITLE            @"Loading"

// Только iOS Simulator: если config.php не вернул url — открыть этот WebView (тест UI).
// Оставьте @"" чтобы выключить. На устройстве и в App Store эта строка не используется.
#define PL_SIMULATOR_FALLBACK_WEBVIEW_URL @""
