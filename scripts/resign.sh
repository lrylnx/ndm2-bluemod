#!/bin/bash
# NDM2 重签名：顺序很重要 —— 先签 PlugIns 里的 .appex，再 deep 签主 App。
# 中断的签名会残留 *.cstemp* 污染 seal，先清理。
APP="$1"
[ -z "$APP" ] && { echo "用法: $0 /path/to/App.app"; exit 1; }
find "$APP" -name "*.cstemp*" -delete 2>/dev/null
for ext in "$APP/Contents/PlugIns/"*.appex; do
  [ -e "$ext" ] || continue
  codesign --force -s - "$ext" || exit 1
done
codesign --force --deep -s - "$APP" || exit 1
codesign --verify --deep "$APP" && echo "SIGN_OK"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
