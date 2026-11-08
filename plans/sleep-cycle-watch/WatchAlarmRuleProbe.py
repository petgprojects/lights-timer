#!/usr/bin/env python3
"""Execute actual decrypted Watch checkForAlarm rule core, 0x997e0..0x99fdc.
Entry preconditions: valid current alarm, future deadline, no delegate override.
Framework/metadata/Swift/logging shims only; fire callback is observed, not run.
"""
import json,hashlib,math,struct
from pathlib import Path
from WatchProbeSupport import read_arm64, probe_arguments
from WatchAlgorithmReference import alarm_rule
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM,UC_HOOK_CODE
from unicorn.arm64_const import *
ROOT=Path(__file__).parent
BASE=0x10000000;DATA=0x20000000;STACK=0x30000000;STUB=0x40000000;STOP=STUB+0xf00
OBJ=DATA;MOV=DATA+0x1000;META=DATA+0x3008;VWT=DATA+0x3100;DEC=DATA+0x3300;LOGGER=DATA+0x4000
TMP=DATA+0x5000;ALARM=DATA+0x6000;TUPLEMETA=DATA+0x7000;FP=STACK+0x8000
class Probe:
 def __init__(self,watch_binary):
  self.blob=read_arm64(watch_binary);self.cpu=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
  for a,s in [(BASE,0x500000),(DATA,0x100000),(STACK,0x10000),(STUB,0x1000)]:self.cpu.mem_map(a,s)
  self.cpu.mem_write(BASE,self.blob)
  self.put64(BASE+0x2406b0,0x100);self.put64(BASE+0x2406b8,0x108)
  self.put64(BASE+0x241340,0xffffffffffffffff);self.put64(BASE+0x24dd00,LOGGER)
  for off in [0x80,0x88,0x90]:self.put64(LOGGER+off,STUB)
  self.put64(META-8,VWT)
  for off,ptr in [(8,STUB),(0x10,STUB+4),(0x20,STUB+4),(0x30,STUB+8),(0x38,STUB+12)]:self.put64(VWT+off,ptr)
  self.cpu.mem_write(TUPLEMETA+0x30,struct.pack('<i',16))
  for offset,value in [(0x14,8),(0x18,16),(0x1c,48),(0x20,49),(0x24,50),(0x28,56)]:self.cpu.mem_write(DEC+offset,struct.pack('<i',value))
  self.hooks={STUB:'noop',STUB+4:'datecopy',STUB+8:'gettag',STUB+12:'settag',BASE+0x1846dc:'decor',BASE+0x74d0:'optionalcopy',BASE+0x1f338:'optionalcopy',BASE+0x1c48fc:'interval',BASE+0x75ac:'noop',BASE+0x1c7c8c:'noop',BASE+0x1c7d4c:'noop',BASE+0x991e0:'fire'}
  self.cpu.hook_add(UC_HOOK_CODE,self.hook)
 def put64(self,a,v):self.cpu.mem_write(a,struct.pack('<Q',v))
 def putdouble(self,a,v):self.cpu.mem_write(a,struct.pack('<d',v))
 def getdouble(self,a):return struct.unpack('<d',self.cpu.mem_read(a,8))[0]
 def x(self,i):return self.cpu.reg_read([UC_ARM64_REG_X0,UC_ARM64_REG_X1,UC_ARM64_REG_X2,UC_ARM64_REG_X3][i])
 def hook(self,cpu,addr,size,data):
  k=self.hooks.get(addr)
  if k is None:return
  if k=='datecopy':cpu.mem_write(self.x(0),bytes(cpu.mem_read(self.x(1),8)))
  elif k=='optionalcopy':cpu.mem_write(self.x(1),bytes(cpu.mem_read(self.x(0),9)))
  elif k=='gettag':cpu.reg_write(UC_ARM64_REG_X0,cpu.mem_read(self.x(0)+8,1)[0])
  elif k=='settag':cpu.mem_write(self.x(0)+8,bytes([self.x(1)]))
  elif k=='decor':cpu.reg_write(UC_ARM64_REG_X0,DEC)
  elif k=='interval':cpu.reg_write(UC_ARM64_REG_D0,struct.unpack('<Q',struct.pack('<d',self.getdouble(cpu.reg_read(UC_ARM64_REG_X20))-self.getdouble(self.x(0))))[0])
  elif k=='fire':self.fires+=1
  elif k!='noop':raise AssertionError(k)
  cpu.reg_write(UC_ARM64_REG_PC,cpu.reg_read(UC_ARM64_REG_LR))
 def run(self,*,now=1000.,deadline=1300.,window=600.,last=None,new=False,active=False,delayed=False,intensity=0.,sensitive=False):
  cpu=self.cpu;self.fires=0
  cpu.mem_write(STACK,bytes(0x10000));cpu.mem_write(TMP,bytes(0x1000))
  self.putdouble(OBJ+0x30,window);cpu.mem_write(OBJ+0x100,bytes([sensitive]));self.putdouble(OBJ+0x108,last or 0.);cpu.mem_write(OBJ+0x110,bytes([last is None]))
  self.putdouble(MOV,now);cpu.mem_write(MOV+48,bytes([new,active,delayed]));self.putdouble(MOV+56,intensity);self.putdouble(ALARM,deadline)
  for off,p in [(0xe0,MOV),(0xe8,OBJ),(0xd8,META),(0xf0,TMP+0x100),(0xf8,TMP+0x200),(0x100,TUPLEMETA),(0x108,TMP+0x300),(0x110,VWT),(0x118,TMP+0x400)]:self.put64(FP-off,p)
  self.put64(FP+8,STOP)
  for r,p in [(UC_ARM64_REG_X29,FP),(UC_ARM64_REG_SP,FP-0x500),(UC_ARM64_REG_X19,TMP),(UC_ARM64_REG_X20,OBJ),(UC_ARM64_REG_X21,META),(UC_ARM64_REG_X22,TMP+0x500),(UC_ARM64_REG_X23,STUB+4),(UC_ARM64_REG_X24,TMP+0x600),(UC_ARM64_REG_X25,STUB+8),(UC_ARM64_REG_X26,MOV),(UC_ARM64_REG_X28,ALARM),(UC_ARM64_REG_LR,STOP)]:cpu.reg_write(r,p)
  try:cpu.emu_start(BASE+0x997e0,STOP,count=10000)
  except Exception as ex:raise RuntimeError(f'PC={cpu.reg_read(UC_ARM64_REG_PC):x}') from ex
  assert cpu.reg_read(UC_ARM64_REG_PC)==STOP
  return dict(fire=bool(self.fires),last=None if cpu.mem_read(OBJ+0x110,1)[0] else self.getdouble(OBJ+0x108))
def expected(case):
 return alarm_rule(**case)
def main():
 args=probe_arguments(__doc__, 'watch-alarm-rule-proof.json')
 cases=[]
 def add(name,**kw):cases.append((name,kw))
 for active in [False,True]:add(f'very_sensitive_active_{active}',sensitive=True,active=active)
 for intensity in [.039999999,.04,.040000001]:
  for last in [None,880.,880.000001,1010.]:add(f'new_intensity_{intensity}_last_{last}',new=True,active=True,intensity=intensity,last=last)
 for elapsed in [0.,10.,10.000001,119.999,120.,10000.]:
  for active in [False,True]:add(f'sustained_elapsed_{elapsed}_active_{active}',last=1000.-elapsed,active=active)
 for intensity in [.099999999,.1,.100000001,.5]:
  for last in [None,900.]:add(f'delayed_intensity_{intensity}_last_{last}',active=True,delayed=True,intensity=intensity,last=last)
 for new in [False,True]:add(f'nil_history_new_{new}',active=True,intensity=.5,new=new)
 p=Probe(args.watch_binary);out=[]
 for name,case in cases:
  actual=p.run(**case);want=expected(case);assert actual==want,(name,case,actual,want)
  out.append(dict(name=name,input=case,result=actual))
 result={'scope':'Actual ARM64 checkForAlarm rule core original instructions at 0x1000997e0..0x100099fdc. Entry requires current alarm, future deadline, no delegate override. Date, Swift metadata/copy/exclusivity and logging are shimmed. Fire callback observed rather than run; upstream deadline/delegate/acquisition are outside this probe.','binarySHA256':hashlib.sha256(p.blob).hexdigest(),'casesPassed':len(out),'cases':out}
 args.output.write_text(json.dumps(result,indent=2));print(json.dumps({'casesPassed':len(out)}))
if __name__=='__main__':main()
