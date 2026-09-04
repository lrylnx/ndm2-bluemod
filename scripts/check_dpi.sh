#!/bin/bash
# 检查 App Resources 内 PNG 的 DPI 元数据。
# NSImage 点尺寸 = 像素 × 72/DPI —— 替换 PNG 时若不保留原 DPI，
# 点尺寸会翻倍/暴增，小容器（如菜单栏状态项）里的图会溢出"消失"。
RES="$1"
[ -z "$RES" ] && { echo "用法: $0 <Resources目录>"; exit 1; }
printf "%-28s %-8s %-8s %s\n" FILE PX DPI PT_SIZE
for f in "$RES"/*.png; do
  b=$(basename "$f")
  px=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/{print $2}')
  dpi=$(sips -g dpiWidth "$f" 2>/dev/null | awk '/dpiWidth/{print $2}')
  pt=$(python3 -c "print(f'{$px*72/${dpi:-72}:.1f}')")
  printf "%-28s %-8s %-8s %s\n" "$b" "$px" "${dpi:-?}" "$pt"
done
echo "提示: 与原版对比 DPI，替换后务必用 sips -s dpiWidth/-s dpiHeight 恢复。"
