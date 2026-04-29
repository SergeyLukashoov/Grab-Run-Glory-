#!/usr/bin/env python3
"""
patch_infoplist.py — дополняет Info.plist:

  • NSCameraUsageDescription и NSMicrophoneUsageDescription при отсутствии.
  • ITSAppUsesNonExemptEncryption при отсутствии.
  • UISupportedInterfaceOrientations (и ~ipad): объединяет с полным списком
    интерфейсных ориентаций — нужно чтобы WebView мог поворачиваться во все
    стороны (локф для Unity остаётся в коде).

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

# Максимум интерфейсов в Info.plist нужен, чтобы WebView мог крутиться во все стороны
# (фактическая маска задаётся кодом; игра в Unity остаётся в landscape right).
UI_ORIENTATION_KEYS = (
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
)


def merge_supported_interface_orientations(data: dict) -> bool:
    changed = False
    for plist_key in (
        "UISupportedInterfaceOrientations",
        "UISupportedInterfaceOrientations~ipad",
    ):
        arr = data.get(plist_key)
        if arr is None:
            arr = []
            data[plist_key] = arr
            changed = True
        if not isinstance(arr, list):
            continue
        existing = set(arr)
        for o in UI_ORIENTATION_KEYS:
            if o not in existing:
                arr.append(o)
                existing.add(o)
                changed = True
                print(f"[patch_infoplist]  + {plist_key}: {o}")
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

    if merge_supported_interface_orientations(data):
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
