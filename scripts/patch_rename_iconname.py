#!/usr/bin/env python3
"""把二进制里 imageNamed:@"neaticon" 的 cstring 原地改名成 "Template"。

⚠️ 已废弃（v2.2）：这个方案会连带影响 NeatQuitWindow.nib / NeatAboutWindow.nib 里引用的
   同一张图（退出/关于对话框的彩色图标会跟着变单色），因此实际采用的是
   「新资源 neaticonTemplate.png + ndm_statusicon.dylib」方案，见 docs/STATUS_ICON.md。
   本脚本保留，作为「macOS 资源命名约定 + 二进制等长原地改写」的参考实现。

原理：macOS 的 +[NSImage imageNamed:] 有个约定 —— 资源名以 "Template" 结尾时，
返回的 NSImage 会自动 isTemplate=YES，状态栏按钮会按菜单栏明暗自动渲染成黑/白。
"neaticon"(8) 与 "Template"(8) 等长，可原地改写，无需插入指令、无需 dylib。

用法: patch_rename_iconname.py <app_binary> [old_name] [new_name]
"""
import struct, sys, os, shutil

def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]

MH_MAGIC_64 = 0xFEEDFACF
SEGMENT_64 = 0x19

def cstring_sections(sl, base):
    """返回该 slice 中 (segname,sectname,addr,size,fileoff) 列表"""
    ncmds = u32(sl, 16)
    off = 32
    out = []
    for _ in range(ncmds):
        cmd = u32(sl, off); sz = u32(sl, off + 4)
        if cmd == SEGMENT_64:
            for i in range(u32(sl, off + 64)):
                s = off + 72 + 80 * i
                sect = sl[s:s + 16].split(b"\0")[0].decode()
                seg = sl[s + 16:s + 32].split(b"\0")[0].decode()
                out.append((seg, sect, u64(sl, s + 32), u64(sl, s + 40), u32(sl, s + 48)))
        off += sz
    return out

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    path = sys.argv[1]
    old = (sys.argv[2] if len(sys.argv) > 2 else "neaticon").encode()
    new = (sys.argv[3] if len(sys.argv) > 3 else "Template").encode()
    if len(old) != len(new):
        print(f"FAILED: 长度不等 {old!r} vs {new!r} — 必须等长才能原地改写"); sys.exit(1)

    data = bytearray(open(path, "rb").read())
    is_fat = data[:4] == b"\xca\xfe\xba\xbe"
    slices = []
    if is_fat:
        n = struct.unpack_from(">I", data, 4)[0]
        for i in range(n):
            off = struct.unpack_from(">I", data, 8 + 20 * i + 8)[0]
            slices.append(off)
    else:
        slices = [0]

    total = 0
    for base in slices:
        sl = bytes(data[base:])
        if u32(sl, 0) != MH_MAGIC_64:
            print(f"slice@{base:#x}: 非 MH_MAGIC_64，跳过"); continue
        found = 0
        for seg, sect, addr, size, fileoff in cstring_sections(sl, base):
            if sect != "__cstring" or size == 0:
                continue
            blk_fo = base + fileoff
            blk = bytes(data[blk_fo:blk_fo + size])
            start = 0
            while True:
                idx = blk.find(old + b"\0", start)
                if idx < 0: break
                # 必须是独立字符串（前一位是 NUL 或段首）
                if idx == 0 or blk[idx - 1] == 0:
                    fo = blk_fo + idx
                    data[fo:fo + len(new)] = new
                    print(f"slice@{base:#x} {addr + idx:#x} (file {fo:#x}): {old.decode()} -> {new.decode()}")
                    found += 1
                start = idx + 1
        total += found
        if found != 1:
            print(f"!! slice@{base:#x} 命中 {found} 处（预期 1）")
    if total == 0:
        print("FAILED: 未找到目标字符串，文件未写入"); sys.exit(1)

    bak = path + ".bak-rename"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
        print(f"备份 -> {bak}")
    open(path, "wb").write(data)
    print(f"OK: {path} 共改写 {total} 处")

if __name__ == "__main__":
    main()
