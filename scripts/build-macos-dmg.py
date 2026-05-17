#!/usr/bin/env python3
"""
把 flutter build macos 产出的 .app 打包成带品牌背景的 .dmg 安装镜像。
输出: dist/deployment-<version>-macos.dmg
依赖: dmgbuild (会自动安装到 --user)
"""

import os
import re
import site
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "deployment"
DISPLAY_NAME = "Deployment"
APP_PATH = ROOT / f"build/macos/Build/Products/Release/{APP_NAME}.app"
DIST_DIR = ROOT / "dist"
BG_IMG = ROOT / "scripts/dmg-background.png"
ICNS_DIR = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
PUBSPEC = ROOT / "pubspec.yaml"


def ensure_dmgbuild():
    try:
        import dmgbuild  # noqa: F401
        return
    except ImportError:
        pass

    print("正在安装 dmgbuild...")
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "--user", "dmgbuild"]
    )
    # 让当前进程能立刻 import 到刚装的包
    user_site = site.getusersitepackages()
    if user_site not in sys.path:
        sys.path.insert(0, user_site)


def read_version():
    with open(PUBSPEC, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^version:\s*([^+\s]+)", line)
            if m:
                return m.group(1)
    raise RuntimeError("pubspec.yaml 中未找到 version 字段")


def find_volicon():
    for icns in ICNS_DIR.rglob("*.icns"):
        return str(icns)
    return None


def main():
    if not APP_PATH.is_dir():
        sys.exit(f"找不到 {APP_PATH}，请先执行 flutter build macos")

    ensure_dmgbuild()
    import dmgbuild

    version = read_version()
    dmg_path = DIST_DIR / f"{APP_NAME}-{version}-macos.dmg"
    vol_name = f"{DISPLAY_NAME} {version}"

    DIST_DIR.mkdir(parents=True, exist_ok=True)
    if dmg_path.exists():
        dmg_path.unlink()

    settings = {
        "files": [str(APP_PATH)],
        "symlinks": {"Applications": "/Applications"},
        "format": "UDZO",
        "compression_level": 9,
        "background": str(BG_IMG),
        "window_rect": ((60, 50), (660, 500)),
        "default_view": "icon-view",
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
        "show_icon_preview": False,
        "icon_size": 100,
        "text_size": 12,
        "icon_locations": {
            APP_PATH.name: (165, 220),
            "Applications": (495, 220),
        },
    }

    volicon = find_volicon()
    if volicon:
        settings["icon"] = volicon

    print("打包 DMG...")
    dmgbuild.build_dmg(
        filename=str(dmg_path),
        volume_name=vol_name,
        settings=settings,
    )

    size_mb = dmg_path.stat().st_size / (1024 * 1024)
    rel = dmg_path.relative_to(ROOT)
    print(f"✓ 安装包已生成: {rel} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
