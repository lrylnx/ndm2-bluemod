#!/usr/bin/env python3
"""
NDM2 通用扩展名图标 hook（arm64）。

原逻辑：行图标函数只硬编码 3 对扩展名比较（zip/pdf/exe -> imageNamed:），
其余扩展名走 NSWorkspace iconForFile: 系统图标。

本补丁把函数旁一段死代码（0x10002fb00，lowercaseString -> imageNamed: helper，
全 __text 扫描确认零调用者）改写为通用查询 stub：
    ext -> lowercaseString -> [NSImage imageNamed:] -> nil 则跳回原系统图标回退
再把第三个比较失败的 cbz 改道到 stub。
效果：Resources 里放 <扩展名>.png 即可显示自定义图标，无需再改二进制。

用法: python3 patch_ext_icon_hook.py /path/to/NeatDownloadManager2.app
"""
import struct, sys, shutil, os

def main(app):
    bin_path = os.path.join(app, 'Contents/MacOS/NeatDownloadManager')
    bak = bin_path + '.before_exthook'
    shutil.copy(bin_path, bak)
    data = bytearray(open(bak, 'rb').read())

    magic, nfat = struct.unpack_from('>II', data, 0)
    arm = None
    for i in range(nfat):
        cput, cpusub, off, size, align = struct.unpack_from('>IIIII', data, 8+i*20)
        if cput == 0x0100000C: arm = off
    assert arm is not None, 'arm64 slice not found'

    d = bytearray(data[arm:])
    ncmds = struct.unpack_from('<I', d, 16)[0]
    off = 32; sects = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', d, off)
        if cmd == 0x19:
            sg = d[off+8:off+24].rstrip(b'\0').decode()
            ns = struct.unpack_from('<I', d, off+64)[0]; so = off+72
            for i in range(ns):
                sn = d[so:so+16].rstrip(b'\0').decode()
                a, sz, f = struct.unpack_from('<QQI', d, so+32)
                sects.append((sg, sn, a, sz, f)); so += 80
        off += cs
    def fo(vm):
        for sg, sn, a, sz, f in sects:
            if a <= vm < a+sz: return f + (vm-a)
        raise ValueError(hex(vm))

    TVA, TSZ, TF = [(a, sz, f) for sg, sn, a, sz, f in sects if sn == '__text'][0]

    # --- 安全检查 1: helper 0x10002fb00 必须是死代码（无 bl/b 指向） ---
    for k in range(0, TSZ-4, 4):
        insn = struct.unpack_from('<I', d, TF+k)[0]
        va = TVA + k
        if (insn & 0xFC000000) in (0x94000000, 0x14000000):
            imm26 = insn & 0x3FFFFFF
            if imm26 > 2**25: imm26 -= 2**26
            assert va + imm26*4 != 0x10002fb00, f'helper 被 {hex(va)} 调用，中止'

    def ldr_lit(va, target, rt):
        imm = (target - va) >> 2
        assert -2**18 <= imm < 2**18 and (target & 3) == 0
        return 0x58000000 | ((imm & 0x7FFFF) << 5) | rt
    def bl(va, target):
        imm = (target - va) >> 2
        assert 0 <= imm < 2**26
        return 0x94000000 | imm
    def cbz_x0(va, target):
        imm = (target - va) >> 2
        assert -2**18 <= imm < 2**18
        return 0xB4000000 | ((imm & 0x7FFFF) << 5)
    def b_(va, target):
        imm = (target - va) >> 2
        assert 0 <= imm < 2**26
        return 0x14000000 | imm

    MSGSEND      = 0x100077b88
    SEL_LOWER    = 0x1000d5320   # lowercaseString selref
    CLS_NSIMAGE  = 0x1000d5ba8   # NSImage classref (got)
    SEL_IMGNAMED = 0x1000d4b68   # imageNamed: selref
    FALLBACK     = 0x10002fd80   # 原系统图标回退入口
    EPILOGUE     = 0x10002fe64   # 函数收尾（objc_retainAutoreleasedReturnValue...）

    stub = [
        0xAA1303E0,                        # mov x0, x19   (扩展名字符串)
        ldr_lit(0x10002fb04, SEL_LOWER, 1),
        bl(0x10002fb08, MSGSEND),
        0xAA0003F5,                        # mov x21, x0
        ldr_lit(0x10002fb10, CLS_NSIMAGE, 0),
        ldr_lit(0x10002fb14, SEL_IMGNAMED, 1),
        0xAA1503E2,                        # mov x2, x21
        bl(0x10002fb1c, MSGSEND),
        cbz_x0(0x10002fb20, FALLBACK),     # nil -> 原回退（iconForFile:）
        b_(0x10002fb24, EPILOGUE),         # 命中 -> 返回图片
    ]
    # --- 安全检查 2: stub 覆盖区必须是已知的死代码序言 ---
    prologue = struct.unpack_from('<IIII', d, fo(0x10002fb00))
    assert prologue[0] == 0xa9b64ffa, f'{prologue[0]:08x}'  # stp x26,x25,[sp,#-0x50]!
    for i, enc in enumerate(stub):
        struct.pack_into('<I', d, fo(0x10002fb00 + i*4), enc)

    # --- 改道: 第三个比较失败 cbz w0, 原回退 -> stub ---
    o = fo(0x10002fd58)
    old = struct.unpack_from('<I', d, o)[0]
    assert (old & 0xFF000000) == 0x34000000 and (old & 31) == 0
    imm = (0x10002fb00 - 0x10002fd58) >> 2
    struct.pack_into('<I', d, o, 0x34000000 | ((imm & 0x7FFFF) << 5))

    data[arm:arm+len(d)] = d
    open(bin_path, 'wb').write(data)
    print('arm64 hook 注入完成。备份:', bak)

if __name__ == '__main__':
    main(sys.argv[1])
