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

// Базовый URL вашего сервера (без завершающего слэша и без "/config.php").
// Эндпоинт запроса: EL_ENDPOINT_URL + "/config.php"
#define EL_ENDPOINT_URL             @"https://grab-run-glory.com"

// Заголовок на экране загрузки (название вашего приложения)
#define EL_LOADING_TITLE            @"Loading"
