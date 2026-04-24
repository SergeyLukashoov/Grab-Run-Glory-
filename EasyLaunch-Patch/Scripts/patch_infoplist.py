#!/usr/bin/env python3
"""
patch_infoplist.py
──────────────────
Патчит Info.plist:
  1. Добавляет NSCameraUsageDescription, NSMicrophoneUsageDescription,
     ITSAppUsesNonExemptEncryption если их ещё нет.
  2. Обеспечивает наличие ВСЕХ четырёх ориентаций в
     UISupportedInterfaceOrientations (и …~ipad), чтобы приложение
     могло показывать разные ориентации в WebView.
     Рантайм-ограничение (portrait в Unity, all в WebView)
     делается через application:supportedInterfaceOrientationsForWindow:
     в CustomAppController.

Использование:
    python3 patch_infoplist.py <path/to/Info.plist>
"""

import sys
import plistlib
import os

KEYS = {
    "NSCameraUsageDescription":     "This app requires access to the camera.",
    "NSMicrophoneUsageDescription": "This app requires access to the microphone.",
    "ITSAppUsesNonExemptEncryption": False,
}

ALL_ORIENTATIONS = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]

ORIENTATION_KEYS = [
    "UISupportedInterfaceOrientations",
    "UISupportedInterfaceOrientations~ipad",
]


def ensure_orientations(data: dict) -> bool:
    """Гарантирует, что в Info.plist разрешены все 4 ориентации
    для iPhone и iPad. Возвращает True если были изменения."""
    changed = False
    for key in ORIENTATION_KEYS:
        existing = data.get(key)
        if not isinstance(existing, list):
            data[key] = list(ALL_ORIENTATIONS)
            print(f"[patch_infoplist]  + {key} (all 4 orientations)")
            changed = True
            continue

        missing = [o for o in ALL_ORIENTATIONS if o not in existing]
        if missing:
            existing.extend(missing)
            data[key] = existing
            for o in missing:
                print(f"[patch_infoplist]  + {key} -> {o}")
            changed = True
        else:
            print(f"[patch_infoplist]  = {key} (все 4 ориентации уже есть)")
    return changed


def patch(plist_path: str) -> None:
    if not os.path.isfile(plist_path):
        print(f"[patch_infoplist] ERROR: file not found: {plist_path}", file=sys.stderr)
        sys.exit(1)

    with open(plist_path, "rb") as f:
        data = plistlib.load(f)

    changed = False
    for key, value in KEYS.items():
        if key not in data:
            data[key] = value
            print(f"[patch_infoplist]  + {key}")
            changed = True
        else:
            print(f"[patch_infoplist]  = {key} (уже присутствует, пропуск)")

    if ensure_orientations(data):
        changed = True

    if changed:
        with open(plist_path, "wb") as f:
            plistlib.dump(data, f)
        print("[patch_infoplist] Info.plist обновлён.")
    else:
        print("[patch_infoplist] Info.plist не изменён.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Использование: {sys.argv[0]} <path/to/Info.plist>", file=sys.stderr)
        sys.exit(1)
    patch(sys.argv[1])
