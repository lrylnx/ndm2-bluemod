#!/usr/bin/env python3
"""ndm2-bluemod 图标生成器 v2
产出：
  icons/svg/*.png徽章源     扩展名徽章（按类别配色，圆角方块+双层渐变+内描边+白字）
  icons/sidebar/*.svg       侧边栏分类徽章（类别配色 + 白色图形）
  icons/toolbar/*.svg       工具栏（轻量描线风，#2E8AE6 单色描边，透明底）
配套 build_icons.sh 渲染为 PNG 并写回目标 DPI。
"""
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(ROOT, "svg")
SIDE = os.path.join(ROOT, "sidebar")
TOOL = os.path.join(ROOT, "toolbar")
for d in (SVG, SIDE, TOOL):
    os.makedirs(d, exist_ok=True)

# ---------------- 类别配色（light → dark 渐变） ----------------
CAT = {
    "blue":    ("#5FB2FF", "#2E8AE6"),   # 文档
    "amber":   ("#FFC24D", "#D97706"),   # 压缩包
    "violet":  ("#C084FC", "#7C3AED"),   # 视频
    "teal":    ("#2DD4BF", "#0D9488"),   # 音频
    "rose":    ("#F9A8D4", "#DB2777"),   # 图片
    "green":   ("#4ADE80", "#16A34A"),   # 电子书
    "indigo":  ("#818CF8", "#4F46E5"),   # 程序/安装包
    "slate":   ("#94A3B8", "#475569"),   # 磁盘镜像
    "cyan":    ("#22D3EE", "#0891B2"),   # 种子
    "orange":  ("#FDBA74", "#EA580C"),   # 未完成/计时
}

EXT_CAT = {
    # 压缩包
    "7z": "amber", "bz2": "amber", "gz": "amber", "rar": "amber",
    "tgz": "amber", "xz": "amber", "zip": "amber",
    # 视频
    "avi": "violet", "flv": "violet", "m3u8": "violet", "m4s": "violet",
    "mkv": "violet", "mov": "violet", "mp4": "violet", "mpeg": "violet",
    "mpg": "violet", "rmvb": "violet", "ts": "violet", "webm": "violet",
    # 音频
    "aac": "teal", "flac": "teal", "m4a": "teal", "mp3": "teal",
    "ogg": "teal", "opus": "teal", "wav": "teal", "wma": "teal",
    # 图片
    "bmp": "rose", "gif": "rose", "heic": "rose", "icns": "rose",
    "ico": "rose", "jpeg": "rose", "jpg": "rose", "png": "rose",
    "psd": "rose", "svg": "rose", "tif": "rose", "tiff": "rose", "webp": "rose",
    # 文档
    "csv": "blue", "doc": "blue", "docx": "blue", "md": "blue", "pdf": "blue",
    "ppt": "blue", "pptx": "blue", "txt": "blue", "xls": "blue", "xlsx": "blue",
    # 电子书
    "epub": "green", "mobi": "green",
    # 程序 / 安装包
    "apk": "indigo", "bat": "indigo", "cmd": "indigo", "deb": "indigo",
    "exe": "indigo", "msi": "indigo", "pkg": "indigo", "reg": "indigo",
    # 磁盘镜像
    "dmg": "slate", "iso": "slate",
    # 种子
    "torrent": "cyan",
}

def font_size(n):
    return {1: 40, 2: 34, 3: 30, 4: 25, 5: 20, 6: 17}.get(n, 16)

def badge(label, cat, glyph=None):
    """圆角方块徽章：双层渐变 + 内描边；文字或白色图形"""
    L, D = CAT[cat]
    s = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
<defs>
<linearGradient id="g" x1="0" y1="0" x2="0.55" y2="1">
<stop offset="0" stop-color="{L}"/><stop offset="1" stop-color="{D}"/></linearGradient>
<linearGradient id="s" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#ffffff" stop-opacity="0.30"/>
<stop offset="0.45" stop-color="#ffffff" stop-opacity="0.05"/>
<stop offset="1" stop-color="#000000" stop-opacity="0.10"/></linearGradient>
</defs>
<rect x="5" y="5" width="90" height="90" rx="24" fill="url(#g)"/>
<rect x="5" y="5" width="90" height="90" rx="24" fill="url(#s)"/>
<rect x="6.25" y="6.25" width="87.5" height="87.5" rx="22.75" fill="none" stroke="#ffffff" stroke-opacity="0.35" stroke-width="1.5"/>
'''
    if glyph:
        s += f'<g stroke="#ffffff" stroke-width="6.5" stroke-linecap="round" stroke-linejoin="round" fill="none">{glyph}</g>\n'
    else:
        fs = font_size(len(label))
        s += (f'<text x="50" y="50" text-anchor="middle" dominant-baseline="central" '
              f'font-family="Helvetica, Arial, sans-serif" font-weight="700" '
              f'font-size="{fs}" fill="#ffffff">{label.upper()}</text>\n')
    s += "</svg>"
    return s

# ---------------- 扩展名徽章 ----------------
for ext, cat in sorted(EXT_CAT.items()):
    with open(os.path.join(SVG, ext + ".svg"), "w") as f:
        f.write(badge(ext, cat))
print(f"ext badges: {len(EXT_CAT)}")

# ---------------- 侧边栏分类徽章（图形符号） ----------------
G_CHECK = '<path d="M32 52 L45 65 L70 38"/>'
G_CLOCK = '<circle cx="50" cy="50" r="20"/><path d="M50 38 V52 L60 58"/>'
G_PLAY  = '<path d="M40 32 L70 50 L40 68 Z" fill="#ffffff" stroke="none"/>'
G_NOTE  = '<path d="M44 66 V34 L66 30 V62"/><circle cx="38" cy="66" r="7" fill="#ffffff" stroke="none"/><circle cx="60" cy="62" r="7" fill="#ffffff" stroke="none"/>'
G_ZIP   = '<rect x="32" y="30" width="36" height="40" rx="5"/><path d="M50 30 V44 M44 44 H56 M50 44 V52 M44 52 H56 M50 52 V62 M46 62 H54"/>'
G_PAGE  = '<path d="M36 28 H58 L68 38 V72 H36 Z"/><path d="M58 28 V38 H68"/><path d="M44 50 H60 M44 58 H60"/>'
G_DOTS  = '<circle cx="38" cy="38" r="5" fill="#ffffff" stroke="none"/><circle cx="62" cy="38" r="5" fill="#ffffff" stroke="none"/><circle cx="38" cy="62" r="5" fill="#ffffff" stroke="none"/><circle cx="62" cy="62" r="5" fill="#ffffff" stroke="none"/>'
G_TRAY  = '<path d="M50 28 V52"/><path d="M40 43 L50 54 L60 43"/><path d="M30 62 V70 H70 V62"/>'

SIDEBAR = {
    "all downloads": ("blue", G_TRAY),   "全部下载": ("blue", G_TRAY),
    "complete":      ("green", G_CHECK), "已完成": ("green", G_CHECK),
    "incomplete":    ("orange", G_CLOCK), "未完成": ("orange", G_CLOCK),
    "video":         ("violet", G_PLAY), "视频": ("violet", G_PLAY),
    "audio":         ("teal", G_NOTE),   "音频": ("teal", G_NOTE),
    "compressed":    ("amber", G_ZIP),   "压缩文件": ("amber", G_ZIP),
    "document":      ("blue", G_PAGE),   "文档": ("blue", G_PAGE),
    "misc":          ("slate", G_DOTS),  "杂项": ("slate", G_DOTS),
}
for name, (cat, g) in SIDEBAR.items():
    with open(os.path.join(SIDE, name + ".svg"), "w") as f:
        f.write(badge(None, cat, glyph=g))
print(f"sidebar: {len(SIDEBAR)}")

# ---------------- 工具栏（轻量描线，透明底） ----------------
STROKE = '#2E8AE6'
SW = 7
def line(body, sw=SW, color=STROKE):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">'
            f'<g stroke="{color}" stroke-width="{sw}" stroke-linecap="round" '
            f'stroke-linejoin="round" fill="none">{body}</g></svg>')

TOOLBAR = {
    # 新建下载：下箭头 + 托盘
    "app": line('<path d="M50 20 V52"/><path d="M36 40 L50 54 L64 40"/><path d="M24 62 V76 H76 V62"/>'),
    # 继续：播放三角（描线）
    "Resume": line('<path d="M38 28 L72 50 L38 72 Z"/>'),
    # 停止：双竖条
    "Pause": line('<path d="M40 28 V72"/><path d="M60 28 V72"/>', sw=11),
    # 删除：垃圾桶
    "delete": line('<path d="M28 34 H72"/><path d="M42 34 V26 H58 V34"/>'
                   '<path d="M34 34 L38 76 H62 L66 34"/><path d="M45 46 V64 M55 46 V64"/>', sw=6),
    # 设置：齿轮（中心圆 + 8 齿）
    "options": line('<circle cx="50" cy="50" r="12"/>'
                    '<path d="M50 24 V32 M50 68 V76 M24 50 H32 M68 50 H76 '
                    'M31.6 31.6 L37.3 37.3 M62.7 62.7 L68.4 68.4 M68.4 31.6 L62.7 37.3 M37.3 62.7 L31.6 68.4"/>', sw=6.5),
    # 浏览器：地球
    "browser": line('<circle cx="50" cy="50" r="26"/><ellipse cx="50" cy="50" rx="11" ry="26"/><path d="M24 50 H76"/>', sw=5.5),
    # 关于：i 圆圈
    "about": line('<circle cx="50" cy="50" r="26"/><path d="M50 46 V62"/><path d="M50 35 V36"/>', sw=6.5),
    # 完全退出：电源符号
    "quit": line('<path d="M35 36 A22 22 0 1 0 65 36"/><path d="M50 22 V48"/>'),
    # 新建下载：下箭头入托盘（下载器主操作，语义直观）
    "Newurl": line('<path d="M50 20 V52"/><path d="M36 40 L50 54 L64 40"/><path d="M24 62 V76 H76 V62"/>'),
}
for name, svg in TOOLBAR.items():
    with open(os.path.join(TOOL, name + ".svg"), "w") as f:
        f.write(svg)
print(f"toolbar line: {len(TOOLBAR)}")

# custombtn 三态：小上箭头（28px@144 → 14pt，保持简洁）
with open(os.path.join(TOOL, "custombtnnormal.svg"), "w") as f:
    f.write(line('<path d="M32 60 L50 38 L68 60"/>', sw=9))
with open(os.path.join(TOOL, "custombtnpressed.svg"), "w") as f:
    f.write(line('<path d="M32 60 L50 38 L68 60"/>', sw=9, color='#1D6FBF'))
with open(os.path.join(TOOL, "custombtndisable.svg"), "w") as f:
    f.write(line('<path d="M32 60 L50 38 L68 60"/>', sw=9, color='#B8C4D0'))

# neaticon：状态栏 19pt 图标，保持实心徽章（小尺寸下描线不可读），仅精修
with open(os.path.join(TOOL, "neaticon.svg"), "w") as f:
    f.write(badge(None, "blue",
        glyph='<path d="M50 28 V50"/><path d="M40 41 L50 52 L60 41"/><path d="M34 60 V68 H66 V60"/>'))
print("done")
