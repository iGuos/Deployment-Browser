#!/usr/bin/env bash
set -euo pipefail

# 把 flutter build macos 产出的 .app 打包成带品牌背景的 .dmg 安装镜像。
# 输出:z dist/deployment-<version>-macos.dmg
# 依赖: create-dmg (brew install create-dmg)

cd "$(dirname "$0")/.."

APP_NAME="deployment"
DISPLAY_NAME="Deployment"
APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
DIST_DIR="dist"
BG_IMG="scripts/dmg-background.png"

# ── 检查 .app ──────────────────────────────────────────────────────────────
if [ ! -d "$APP_PATH" ]; then
  echo "找不到 $APP_PATH，请先执行 flutter build macos" >&2
  exit 1
fi

# ── 版本号 ─────────────────────────────────────────────────────────────────
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)
DMG_NAME="${APP_NAME}-${VERSION}-macos.dmg"

# ── 依赖：create-dmg ───────────────────────────────────────────────────────
if ! command -v create-dmg &>/dev/null; then
  echo "正在安装 create-dmg..."
  brew install create-dmg
fi

# ── 准备输出目录 ───────────────────────────────────────────────────────────
mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$DMG_NAME"

# ── 图标路径（用于 DMG 卷图标）────────────────────────────────────────────
ICNS_PATH="macos/Runner/Assets.xcassets/AppIcon.appiconset"
VOL_ICON=""
# 优先使用 icns，找不到则跳过
if find "$ICNS_PATH" -name "*.icns" | grep -q .; then
  VOL_ICON=$(find "$ICNS_PATH" -name "*.icns" | head -1)
fi

# ── 构建 DMG ──────────────────────────────────────────────────────────────
echo "打包 DMG..."

create-dmg \
  --volname "$DISPLAY_NAME $VERSION" \
  ${VOL_ICON:+--volicon "$VOL_ICON"} \
  --background "$BG_IMG" \
  --window-pos 60 50 \
  --window-size 1320 960 \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 330 440 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 990 440 \
  --text-size 14 \
  --no-internet-enable \
  "$DIST_DIR/$DMG_NAME" \
  "$APP_PATH"

# ── 后处理：锁定窗口大小（禁止用户调整）─────────────────────────────────────
echo "锁定 DMG 窗口大小..."
VOL_LABEL="$DISPLAY_NAME $VERSION"
WRITABLE_DMG="$DIST_DIR/${APP_NAME}-${VERSION}-rw.dmg"
MOUNT_POINT="$(mktemp -d)"

hdiutil convert "$DIST_DIR/$DMG_NAME" -format UDRW -o "$WRITABLE_DMG" -quiet
hdiutil attach "$WRITABLE_DMG" -mountpoint "$MOUNT_POINT" -quiet -nobrowse -noverify

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_LABEL"
    open
    delay 1
    tell container window
      set toolbar visible to false
      set statusbar visible to false
      set the bounds to {60, 50, 1380, 1010}
    end tell
    close container window
  end tell
end tell
delay 2
APPLESCRIPT

hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true
rm -rf "$MOUNT_POINT"

# 修改 .DS_Store 中的 bwsp 记录，将窗口宽高写死（防止用户调整后保存）
python3 - "$WRITABLE_DMG" "$VOL_LABEL" <<'PYEOF'
import sys, subprocess, os, tempfile, struct, plistlib

dmg_path, vol_label = sys.argv[1], sys.argv[2]
mount_pt = tempfile.mkdtemp()

subprocess.run(
    ["hdiutil", "attach", dmg_path, "-mountpoint", mount_pt,
     "-quiet", "-nobrowse", "-noverify", "-readwrite"],
    check=True
)

ds_path = os.path.join(mount_pt, ".DS_Store")
if not os.path.exists(ds_path):
    subprocess.run(["hdiutil", "detach", mount_pt, "-quiet", "-force"])
    sys.exit(0)

with open(ds_path, "rb") as f:
    data = bytearray(f.read())

# 定位 bwsp 记录（Finder 窗口状态 binary plist）并替换 WindowBounds
target = b"bwsp"
i = 0
while i < len(data) - 4:
    idx = data.find(target, i)
    if idx == -1:
        break
    # bwsp 记录紧跟一个 4 字节类型标识 "blob" 和 4 字节长度
    blob_tag = data[idx+4:idx+8]
    if blob_tag == b"blob":
        blob_len = struct.unpack_from(">I", data, idx+8)[0]
        blob_start = idx + 12
        blob_data = bytes(data[blob_start:blob_start+blob_len])
        try:
            pl = plistlib.loads(blob_data)
            # 写死窗口边界，覆盖用户可能改动的值
            pl["WindowBounds"] = "{{60, 50}, {1320, 960}}"
            new_blob = plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)
            new_len = struct.pack(">I", len(new_blob))
            data[idx+8:idx+8+4] = new_len
            data[blob_start:blob_start+blob_len] = new_blob
            # 若新 blob 比原来短，填充零字节保持文件结构
            diff = blob_len - len(new_blob)
            if diff > 0:
                data[blob_start+len(new_blob):blob_start+blob_len] = b"\x00" * diff
        except Exception:
            pass
    i = idx + 1

with open(ds_path, "wb") as f:
    f.write(data)

subprocess.run(["hdiutil", "detach", mount_pt, "-quiet", "-force"])
os.rmdir(mount_pt)
PYEOF

rm -f "$DIST_DIR/$DMG_NAME"
hdiutil convert "$WRITABLE_DMG" -format UDZO -imagekey zlib-level=9 \
  -o "$DIST_DIR/$DMG_NAME" -quiet
rm -f "$WRITABLE_DMG"

echo "✓ 安装包已生成: $DIST_DIR/$DMG_NAME"
ls -lah "$DIST_DIR/$DMG_NAME"
