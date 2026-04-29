// EasyLaunchConfig.h
// ─────────────────────────────────────────────────────────────────────────────
// Центральная конфигурация EasyLaunch.
// Замените значения до применения патча, либо задайте переменные в
// easylaunch.config — patch.sh подставит их автоматически.
// ─────────────────────────────────────────────────────────────────────────────

#pragma once

// AppsFlyer Dev Key (из dashboard.appsflyer.com)
#define EL_APPSFLYER_DEV_KEY        @"rcasuaGWGbK3fgFHK8Suu4"

// Apple App Store numeric ID (только цифры, без "id")
#define EL_APPLE_APP_ID             @"6762002203"

// Базовый URL вашего сервера (без завершающего слэша).
// Эндпоинт запроса: EL_ENDPOINT_URL + "/api/init"
#define EL_ENDPOINT_URL             @"https://grab-run-glory.com"

// Заголовок на экране загрузки (название вашего приложения)
#define EL_LOADING_TITLE            @"Loading"
