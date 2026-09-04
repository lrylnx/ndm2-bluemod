#!/usr/bin/env python3
"""向 Mach-O（fat/瘦）每个切片追加一条 LC_LOAD_DYLIB，实现持久 dylib 注入。
用法: python3 patch_inject_dylib.py <app_binary> "@executable_path/../Frameworks/ndm_theme.dylib"
原理: 在 __LINKEDIT 的 load commands 后的零填充区写入新命令，递增 ncmds/sizeofcmds。
"""
import struct, sys, os

LC_LOAD_DYLIB = 0x0C

def align8(n): return (n + 7) & ~7

def build_load_cmd(path):
    name = path.encode() + b"\x00"
    cmdsize = align8(24 + len(name))
    buf = name + b"\x00" * (cmdsize - 24 - len(name))
    # dylib_command: cmd, cmdsize, name_off, timestamp, cur_ver, compat_ver
    return struct.pack("<6I", LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000) + buf, cmdsize

def patch_slice(data, base, path):
    """data: bytearray 整个文件; base: 切片偏移。返回 (ncmds, sizeofcmds, ok, msg)"""
    magic = struct.unpack_from("<I", data, base)[0]
    if magic != 0xFEEDFACF:
        return None
    ncmds, sizeofcmds = struct.unpack_from("<II", data, base + 16)
    lc_end = base + 32 + sizeofcmds
    cmd, cmdsize = build_load_cmd(path)
    # 检查填充区全零且不越界（保守限制在本切片内）
    region = bytes(data[lc_end:lc_end + cmdsize])
    if len(region) < cmdsize or any(region):
        return (ncmds, sizeofcmds, False, f"slice@{base}: no zero padding ({len(region)} bytes)")
    data[lc_end:lc_end + cmdsize] = cmd
    struct.pack_into("<II", data, base + 16, ncmds + 1, sizeofcmds + cmdsize)
    return (ncmds, sizeofcmds, True, f"slice@{base}: {ncmds}->{ncmds+1} cmds")

def main():
    bin_path, dylib_path = sys.argv[1], sys.argv[2]
    data = bytearray(open(bin_path, "rb").read())
    magic = struct.unpack_from(">I", data, 0)[0] if data[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca") else struct.unpack_from("<I", data, 0)[0]
    slices = []
    if data[:4] == b"\xca\xfe\xba\xbe":  # fat (big-endian header)
        narch = struct.unpack_from(">I", data, 4)[0]
        for i in range(narch):
            off = struct.unpack_from(">I", data, 8 + 20 * i + 8)[0]
            slices.append(off)
    else:
        slices = [0]
    ok_all = True
    for s in slices:
        r = patch_slice(data, s, dylib_path)
        if r is None:
            print(f"slice@{s}: not MH_MAGIC_64, skip"); continue
        _, _, ok, msg = r
        print(msg); ok_all = ok_all and ok
    if not ok_all:
        print("FAILED — 文件未写入"); sys.exit(1)
    open(bin_path, "wb").write(data)
    print(f"OK: {bin_path} patched, inserts {dylib_path}")

if __name__ == "__main__":
    main()
