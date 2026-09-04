import struct, sys
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
def vo(f_):
    for sg,sn,a,sz,f in sects:
        if f<=f_<f+sz: return a+(f_-f)
S={(sg,sn):(a,sz,f) for sg,sn,a,sz,f in sects}
mn_a,mn_sz,mn_f=S[('__TEXT','__objc_methname')]
TVA,TSZ,TF=S[('__TEXT','__text')]
# scan all pointer-aligned slots in data sections for ptr to methname
for sel in sys.argv[1:]:
    i=d.find(sel.encode()+b'\x00')
    if i==-1:
        print(sel,'not found'); continue
    nm_vm=mn_a+(i-mn_f)
    slots=[]
    for sg,sn,a,sz,f in sects:
        if not sn.startswith('__objc_') and sg!='__TEXT':
            continue
        for k in range(0, sz-7, 8):
            p=struct.unpack_from('<Q',d,f+k)[0]
            if p==nm_vm:
                slots.append(a+k)
    ss=set(slots)
    hits=[]
    for k in range(0,TSZ-4,4):
        insn=struct.unpack_from('<I',d,TF+k)[0]
        va=TVA+k
        if (insn & 0xFF000000)==0x58000000:
            imm19=(insn>>5)&0x7FFFF
            if imm19>2**18: imm19-=2**19
            if va+(imm19<<2) in ss: hits.append(va)
    print(f'{sel}: slots={[hex(x) for x in slots]} refs={[hex(h) for h in hits]}')
