#!/usr/bin/env python3
"""
NDM2 进度条/状态文字 绿色 → 蓝色 #3D9BFF（arm64 + x64 双切片）
针对特定二进制版本（v1.4 universal），地址含断言校验，版本不符会拒绝执行。
用法: python3 patch_progress_color.py /path/to/NeatDownloadManager2.app
"""
import struct, sys, shutil, os

BLUE = (61/255, 155/255, 1.0)          # #3D9BFF
TRACK = (199/255, 227/255, 1.0)        # 浅蓝轨道

def load_sections(data, slice_off):
    d = data[slice_off:]
    ncmds = struct.unpack_from('<I', d, 16)[0]
    off = 32; sects = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', d, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            ns = struct.unpack_from('<I', d, off+64)[0]
            so = off + 72
            for i in range(ns):
                sn = d[so:so+16].rstrip(b'\0').decode()
                a, sz, f = struct.unpack_from('<QQI', d, so+32)
                sects.append((sg_of(d, off), sn, a, sz, f)); so += 80
        off += cs
    return d, sects

def sg_of(d, off):
    return d[off+8:off+24].rstrip(b'\0').decode()

def main(app):
    bin_path = os.path.join(app, 'Contents/MacOS/NeatDownloadManager')
    bak = bin_path + '.before_bluemod'
    shutil.copy(bin_path, bak)
    data = bytearray(open(bak, 'rb').read())

    magic, nfat = struct.unpack_from('>II', data, 0)
    slices = {}
    for i in range(nfat):
        cput, cpusub, off, size, align = struct.unpack_from('>IIIII', data, 8+i*20)
        slices[cput] = off

    # ---------- arm64 ----------
    arm = slices[0x0100000C]
    d, sects = load_sections(data, arm)
    def fo(vm):
        for sg, sn, a, sz, f in sects:
            if a <= vm < a+sz: return f + (vm-a)
        raise ValueError(f'bad va {hex(vm)}')

    # 1) 主进度条: 池 0x1000927d0 (0.70588 绿) -> 155/255 (蓝通道)
    o = fo(0x1000927d0)
    assert abs(struct.unpack_from('<d', d, o)[0] - 0.70588237) < 1e-5
    struct.pack_into('<d', d, o, 155/255)

    # 2) 指令改道: movi v0 -> ldr d0 [0x10008e110](61/255); movi v2 -> fmov d2 #1.0
    va = 0x1000594e8
    assert struct.unpack_from('<I', d, fo(va))[0] == 0x6f00e400
    imm = (0x10008e110 - va) >> 2
    struct.pack_into('<I', d, fo(va), 0x5C000000 | ((imm & 0x7FFFF) << 5))
    va = 0x1000594ec
    assert struct.unpack_from('<I', d, fo(va))[0] == 0x6f00e402
    struct.pack_into('<I', d, fo(va), 0x1e6e1002)

    # 3) 轨道三池 -> 浅蓝
    for v, val in ((0x1000927d8, TRACK[0]), (0x1000927e0, TRACK[1]), (0x1000927e8, 1.0)):
        struct.pack_into('<d', d, fo(v), val)

    # 4) lblStatus / lblUpdateStatus / lblResumable 绿色文字 -> 蓝
    o = fo(0x100092800); struct.pack_into('<d', d, o, 155/255)          # lblUpdate g
    o = fo(0x10008e3b8); struct.pack_into('<d', d, o, 61/255)           # resumable r
    o = fo(0x10008e3c0); struct.pack_into('<d', d, o, 1.0)              # resumable b
    va = 0x100065108                                                    # lblStatus movi->ldr
    assert struct.unpack_from('<I', d, fo(va))[0] == 0x6f00e400
    imm = (0x10008e110 - va) >> 2
    struct.pack_into('<I', d, fo(va), 0x5C000000 | ((imm & 0x7FFFF) << 5))
    va = 0x10006510c
    assert struct.unpack_from('<I', d, fo(va))[0] == 0x6f00e402
    struct.pack_into('<I', d, fo(va), 0x1e6e1002)

    # 5) 分段线程条 activeBarsColor (15,41,201 深蓝) -> #3D9BFF
    def ldr_target(va):
        w = struct.unpack_from('<I', d, fo(va))[0]
        assert (w & 0xFF000000) == 0x5C000000
        imm19 = (w >> 5) & 0x7FFFF
        if imm19 > 2**18: imm19 -= 2**19
        return va + (imm19 << 2)
    assert ldr_target(0x100007dd0) == 0x10008e0f8
    assert ldr_target(0x100007dd8) == 0x10008e100
    assert ldr_target(0x100007de0) == 0x10008e108
    def patch_ldr(va, target, rt):
        imm = (target - va) >> 2
        struct.pack_into('<I', d, fo(va), 0x5C000000 | ((imm & 0x7FFFF) << 5) | rt)
    patch_ldr(0x100007dd0, 0x10008e110, 0)   # r = 61/255
    patch_ldr(0x100007dd8, 0x1000927d0, 1)   # g = 155/255
    struct.pack_into('<I', d, fo(0x100007de0), 0x1e6e1002)  # b = 1.0

    data[arm:arm+len(d)] = d
    print('arm64 patched')

    # ---------- x64（Rosetta 场景，深蓝近似） ----------
    x64 = slices[0x01000007]
    d, sects = load_sections(data, x64)
    def fo64(vm):
        for sg, sn, a, sz, f in sects:
            if a <= vm < a+sz: return f + (vm-a)
        raise ValueError(f'bad va {hex(vm)}')
    o = fo64(0x100097300)
    assert abs(struct.unpack_from('<d', d, o)[0] - 0.70588237) < 1e-5
    struct.pack_into('<d', d, o, 155/255)
    o = fo64(0x10005c062)                       # movsd xmm1,[pool] -> xmm2 (绿池喂蓝通道)
    assert list(d[o:o+4]) == [0xF2, 0x0F, 0x10, 0x0D]
    d[o+3] = 0x15
    for v, val in ((0x100097308, TRACK[0]), (0x100097310, TRACK[1]), (0x100097318, 1.0)):
        struct.pack_into('<d', d, fo64(v), val)
    data[x64:x64+len(d)] = d
    print('x64 patched')

    open(bin_path, 'wb').write(data)
    print('done. 备份:', bak)

if __name__ == '__main__':
    main(sys.argv[1])
