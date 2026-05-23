# dmgbuild 配置文件 —— 由 build-macos-dmg.sh 通过 -D 传入参数
# 文档: https://dmgbuild.readthedocs.io/

import os

# ── 来自 -D 的参数 ─────────────────────────────────────────────────────────
app_path = defines.get('app_path')
bg_path = defines.get('bg_path')
vol_icon = defines.get('vol_icon', '')

# ── 文件清单 ───────────────────────────────────────────────────────────────
application = app_path
appname = os.path.basename(application)
files = [application]
symlinks = {'Applications': '/Applications'}

# ── 卷图标 ────────────────────────────────────────────────────────────────
if vol_icon:
    icon = vol_icon

# ── 压缩格式（UDZO + zlib-9，与之前一致）─────────────────────────────────
format = 'UDZO'
compression_level = 9

# ── 窗口外观 ──────────────────────────────────────────────────────────────
background = bg_path
window_rect = ((60, 50), (660, 500))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

# ── 图标视图配置 ──────────────────────────────────────────────────────────
icon_size = 100
text_size = 12
icon_locations = {
    appname: (165, 220),
    'Applications': (495, 220),
}
