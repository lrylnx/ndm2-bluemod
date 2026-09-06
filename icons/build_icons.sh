#!/bin/bash
# 渲染 SVG → PNG，并严格保持目标 App 现有文件的 (像素尺寸, DPI) 元数据。
# 用法: build_icons.sh <app_resources_dir> [name1 name2 ...]
#   不带 name 参数 = 重建全部映射图标
# 映射规则:
#   icons/svg/<ext>.svg        -> Resources/<ext>.png
#   icons/sidebar/<n>.svg      -> Resources/<n>.png
#   icons/toolbar/<n>.svg      -> Resources/<n>.png
#   icons/browser/<n>.svg      -> Resources/<n>.png  (浏览器窗口内各浏览器图标)
set -e
RES="$1"; shift
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/dist_out"; mkdir -p "$OUT"

# 编译渲染器（带 DPI 参数）
REND="$OUT/render_hd"
if [ ! -x "$REND" ] || [ "$ROOT/render/render_hd.swift" -nt "$REND" ]; then
  swiftc -O -o "$REND" "$ROOT/render/render_hd.swift"
fi

render_one() {  # $1=svg $2=px $3=dpi $4=outpng
  "$REND" "$1" "$2" "$4" >/dev/null
  sips -s dpiWidth "$3" -s dpiHeight "$3" "$4" >/dev/null
}

deploy() {  # $1=svg路径 $2=目标png文件名
  local svg="$1" dst="$RES/$2"
  [ -f "$dst" ] || { echo "SKIP (not installed): $2"; return; }
  local px dpi
  px=$(sips -g pixelWidth "$dst" | awk '/pixelWidth/{print $2}')
  dpi=$(sips -g dpiWidth "$dst" | awk '/dpiWidth/{print $2}')
  render_one "$svg" "$px" "$dpi" "$OUT/$2"
  cp "$OUT/$2" "$dst"
  echo "OK $2 ${px}px@${dpi}"
}

if [ $# -gt 0 ]; then
  for n in "$@"; do
    for d in svg sidebar toolbar; do
      [ -f "$ROOT/$d/$n.svg" ] && deploy "$ROOT/$d/$n.svg" "$n.png" && break
    done
  done
else
  for f in "$ROOT"/svg/*.svg; do deploy "$f" "$(basename "${f%.svg}").png"; done
  for f in "$ROOT"/sidebar/*.svg; do deploy "$f" "$(basename "${f%.svg}").png"; done
  for f in "$ROOT"/toolbar/*.svg; do deploy "$f" "$(basename "${f%.svg}").png"; done
  for f in "$ROOT"/browser/*.svg; do deploy "$f" "$(basename "${f%.svg}").png"; done
fi
echo DONE
