#!/usr/bin/env python3
"""Runs original decrypted FastMovementAnalyzer instructions with OS/runtime shims.
No proprietary algorithm instruction is substituted. Shims supply Date/protocol
access, Swift allocation/refcount/exclusivity, libc zero/exp, and vDSP mean.
"""
import hashlib,json,math,struct,random
from pathlib import Path
from WatchProbeSupport import read_arm64, probe_arguments
from WatchAlgorithmReference import FastMovementAnalyzer as Model
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
ROOT=Path(__file__).parent
BASE=0x10000000;DATA=0x20000000;STACK=0x30000000;STUB=0x40000000;STOP=STUB+0xf00
OBJ=DATA;MOV=DATA+0x1000;OUT=DATA+0x2000;META=DATA+0x3008;VWT=DATA+0x3100;WIT=DATA+0x3200;DEC=DATA+0x3300
CONFIGS={
 'watch':dict(file='SCWatchExtension-arm64',ctor=0x178368,update=0x1784c8,stackptr=0x230860,guardptr=0x230888,alloc=0x1c61ec,zero=0x1c7644,exp=0x1c7788,date=0x1c49c8,project=0x7520,datevalue=0x1c4860,decor=0x1846dc,begin=0x1c7c8c,end=0x1c7d4c,unique=0x1c7efc,retain=0x1c7cb0,release=0x1c7c98,mean=0x1c80e8),
 'phone':dict(file='GMFoundation-arm64',ctor=0xabc38,update=0xabd6c,stackptr=0x264c08,guardptr=0x264c28,alloc=0x1c49cc,zero=0x1c5f8c,exp=0x1c6010,date=0x1c3cf4,project=0x8414,datevalue=0x1c3c28,decor=0xe0448,begin=0x1c6454,end=0x1c6544,unique=0x1c66e8,retain=0x1c6478,release=0x1c6460,mean=0x1c68c8)
}
class Emulator:
 def __init__(self,which,limit,binary_path):
  self.c=CONFIGS[which];self.blob=read_arm64(binary_path);self.cpu=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
  for a,s in [(BASE,0x500000),(DATA,0x100000),(STACK,0x10000),(STUB,0x1000)]:self.cpu.mem_map(a,s)
  self.cpu.mem_write(BASE,self.blob);self.heap=DATA+0x10000;self.vector=(0,0,0);self.time=0
  self.put64(BASE+self.c['stackptr'],STUB);self.put64(BASE+self.c['guardptr'],DATA+0x3400);self.put64(DATA+0x3400,0x5432187654321)
  self.put64(META-8,VWT);self.put64(VWT+0x40,8);self.put64(VWT+8,STUB+4);self.put64(VWT+0x20,STUB+8)
  self.put64(MOV+0x18,META);self.put64(MOV+0x20,WIT);self.put64(WIT+8,STUB+12);self.put64(WIT+0x10,STUB+16)
  for offset,value in [(0x14,8),(0x18,16),(0x1c,48),(0x20,49),(0x24,50),(0x28,56)]:self.cpu.mem_write(DEC+offset,struct.pack('<i',value))
  self.hooks={BASE+v:k for k,v in self.c.items() if isinstance(v,int) and k not in ['ctor','update','stackptr','guardptr']}
  for a,k in [(STUB,'noop'),(STUB+4,'noop'),(STUB+8,'datecopy'),(STUB+12,'daterecord'),(STUB+16,'acceleration')]:self.hooks[a]=k
  self.cpu.hook_add(UC_HOOK_CODE,self.hook)
  self.cpu.reg_write(UC_ARM64_REG_D0,struct.unpack('<Q',struct.pack('<d',limit))[0]);self.run(self.c['ctor'])
  self.threshold=self.getdouble(OBJ+0xd8)
 def put64(self,a,v):self.cpu.mem_write(a,struct.pack('<Q',v))
 def get64(self,a):return struct.unpack('<Q',self.cpu.mem_read(a,8))[0]
 def getdouble(self,a):return struct.unpack('<d',self.cpu.mem_read(a,8))[0]
 def setdouble(self,a,v):self.cpu.mem_write(a,struct.pack('<d',v))
 def x(self,i):return self.cpu.reg_read([UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2,UC_ARM64_REG_X3][i])
 def d0(self,v):self.cpu.reg_write(UC_ARM64_REG_D0,struct.unpack('<Q',struct.pack('<d',v))[0])
 def hook(self,cpu,addr,size,data):
  k=self.hooks.get(addr)
  if k is None:return
  if k=='alloc':
   p=self.heap;self.heap+=0x2000;self.put64(p+0x18,602);cpu.reg_write(UC_ARM64_REG_X0,p)
  elif k=='zero':cpu.mem_write(self.x(0),bytes(self.x(1)))
  elif k=='exp':self.d0(math.exp(struct.unpack('<d',struct.pack('<Q',cpu.reg_read(UC_ARM64_REG_D0)))[0]))
  elif k=='date':cpu.reg_write(UC_ARM64_REG_X0,META)
  elif k=='datevalue':self.d0(self.getdouble(cpu.reg_read(UC_ARM64_REG_X20)))
  elif k=='decor':cpu.reg_write(UC_ARM64_REG_X0,DEC)
  elif k=='unique':cpu.reg_write(UC_ARM64_REG_X0,1)
  elif k=='mean':
   vals=[self.getdouble(self.x(0)+i*self.x(1)*8) for i in range(self.x(3))];self.setdouble(self.x(2),sum(vals)/len(vals))
  elif k=='datecopy':cpu.mem_write(self.x(0),bytes(cpu.mem_read(self.x(1),8)))
  elif k=='daterecord':self.setdouble(cpu.reg_read(UC_ARM64_REG_X8),self.time)
  elif k=='acceleration':
   cpu.reg_write(UC_ARM64_REG_Q0,int.from_bytes(struct.pack('<2d',*self.vector[:2]),'little'));cpu.reg_write(UC_ARM64_REG_Q1,int.from_bytes(struct.pack('<2d',self.vector[2],0),'little'))
  elif k not in ['project','begin','end','retain','release','noop']:raise AssertionError(k)
  cpu.reg_write(UC_ARM64_REG_PC,cpu.reg_read(UC_ARM64_REG_LR))
 def run(self,addr):
  self.cpu.reg_write(UC_ARM64_REG_SP,STACK+0x8000);self.cpu.reg_write(UC_ARM64_REG_X20,OBJ);self.cpu.reg_write(UC_ARM64_REG_LR,STOP)
  self.cpu.emu_start(BASE+addr,STOP,count=100000)
  if self.cpu.reg_read(UC_ARM64_REG_PC)!=STOP:raise AssertionError('instruction budget')
 def update(self,t,vec):
  self.time=t;self.vector=vec;self.cpu.mem_write(OUT,bytes(64));self.cpu.reg_write(UC_ARM64_REG_X0,MOV);self.cpu.reg_write(UC_ARM64_REG_X8,OUT);self.run(self.c['update'])
  return {'new':bool(self.cpu.mem_read(OUT+48,1)[0]),'inProgress':bool(self.cpu.mem_read(OUT+49,1)[0]),'delayed':bool(self.cpu.mem_read(OUT+50,1)[0]),'intensity':self.getdouble(OUT+56),'counter':self.get64(OBJ+0x88),'historyIndex':self.get64(OBJ+0xa8),'lastActiveTime':None if self.cpu.mem_read(OBJ+0x28,1)[0] else self.getdouble(OBJ+0x20)}
def compare(a,b):
 for k in a:
  if isinstance(a[k],float):
   if b[k] is None or abs(a[k]-b[k])>1e-10:raise AssertionError((k,a,b))
  elif a[k]!=b[k]:raise AssertionError((k,a,b))
def main():
 args=probe_arguments(__doc__, 'watch-movement-proof.json', phone=True)
 paths={'watch':args.watch_binary,'phone':args.phone_binary}
 result={'scope':'Original decrypted watch and phone FastMovementAnalyzer instructions executed with framework/runtime shims; no sensor hardware, scheduler, or complete app execution.','binaries':{},'constructorCases':[],'traces':[]};total=0
 for which in CONFIGS:result['binaries'][which]=hashlib.sha256(read_arm64(paths[which])).hexdigest()
 for limit in [0,.001,.01,.039999999,.04,.09000000000000001,.327,.5]:
  es=[Emulator(k,limit,paths[k]) for k in ['watch','phone']];expected=Model(limit).threshold
  for e in es:assert abs(e.threshold-expected)<1e-12
  result['constructorCases'].append({'dLimit':limit,'watch':es[0].threshold,'phone':es[1].threshold,'formula':expected});total+=2
 rng=random.Random(20261107)
 cases=[('rest_and_step_actual_watch_default',.09000000000000001,[(i*.02,(0 if i<100 or i>=250 else .12,0,1)) for i in range(900)]),('slow_drift',.04,[(i*.02,(i*0.00005,0,1)) for i in range(1300)]),('random_3_axes',.04,[(i*.02,tuple(rng.uniform(-.08,.08)+(1 if k==2 else 0) for k in range(3))) for i in range(1000)]),('exact_threshold',.04,[(0,(0,0,1)),(.1,(.04,0,1)),(.2,(.0400000001,0,1))]),('quiet_10_second_boundary',.04,[(0,(0,0,1)),(.1,(.08,0,1)),(1,(0,0,1)),(11,(0,0,1)),(11.00001,(0,0,1)),(12,(.08,0,1))])]
 for name,limit,seq in cases:
  watch=Emulator('watch',limit,paths['watch']);phone=Emulator('phone',limit,paths['phone']);model=Model(limit);events=[]
  for i,(t,v) in enumerate(seq):
   a=watch.update(t,v);b=phone.update(t,v);m=model.update(t,v);compare(a,b);compare(a,m);total+=2
   if a['new'] or a['delayed']:events.append({'index':i,'time':t,'vector':v,**a})
  result['traces'].append({'name':name,'samples':len(seq),'events':events,'final':a})
 result['comparisonsPassed']=total
 args.output.write_text(json.dumps(result,indent=2));print(json.dumps({'comparisonsPassed':total,'traces':[(x['name'],x['samples'],len(x['events'])) for x in result['traces']]}))
if __name__=='__main__':main()
