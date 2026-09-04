import struct, sys
from capstone import *
BIN='/Applications/NeatDownloadManager2.app/Contents/MacOS/NeatDownloadManager'
data=open(BIN,'rb').read()
magic,nfat=struct.unpack_from('>II',data,0)
for i in range(nfat):
    cput,cpusub,off,size,align=struct.unpack_from('>IIIII',data,8+i*20)
    if cput==0x0100000C: d=data[off:off+size]
ncmds=struct.unpack_from('<I',d,16)[0]; off=32; sects=[]
for _ in range(ncmds):
    cmd,cs=struct.unpack_from('<II',d,off)
    if cmd==0x19:
        sg=d[off+8:off+24].rstrip(b'\0').decode()
        ns=struct.unpack_from('<I',d,off+64)[0]; so=off+72
        for i in range(ns):
            sn=d[so:so+16].rstrip(b'\0').decode()
            a,sz,f=struct.unpack_from('<QQI',d,so+32)
            sects.append((sg,sn,a,sz,f)); so+=80
    off+=cs
def fo(vm):
    for sg,sn,a,sz,f in sects:
        if a<=vm<a+sz: return f+(vm-a)
start=int(sys.argv[1],16); n=int(sys.argv[2]) if len(sys.argv)>2 else 60
md=Cs(CS_ARCH_ARM64,CS_MODE_LITTLE_ENDIAN)
fofs=fo(start)
code=d[fofs:fofs+n*4]
# build selref name resolver
def selname(va):
    f2=fo(va)
    if f2 is None: return None
    ptr=struct.unpack_from('<Q',d,f2)[0]
    f3=fo(ptr)
    if f3 is None: return None
    e=d.find(b'\x00',f3)
    return d[f3:e].decode('utf-8','replace')
for insn in md.disasm(code,start):
    line=f'{hex(insn.address)}  {insn.mnemonic} {insn.op_str}'
    # annotate ldr of selref/cf pools
    if insn.mnemonic=='ldr' and '#' in insn.op_str:
        try:
            tgt=int(insn.op_str.split('#')[1].split(']')[0],16)
            nm=selname(tgt)
            if nm: line+=f'   ; sel="{nm}"'
        except: pass
    print(line)
