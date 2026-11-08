#!/usr/bin/env python3
"""Execute the actual complete watch extendedFilterForArmedPhase function."""
from WatchAlarmRuleProbe import *
from WatchAlgorithmReference import armed_filter
FILTER=DATA+0x8000;OUT=DATA+0x9000
class FilterProbe(Probe):
 def __init__(self,watch_binary):
  super().__init__(watch_binary);self.put64(BASE+0x2406d0,0x120);self.put64(BASE+0x2406d8,0x128);self.put64(OBJ+0x120,FILTER)
  self.hooks[BASE+0x1c49c8]='date';self.hooks[BASE+0x1c4860]='value'
 def hook(self,cpu,addr,size,data):
  k=self.hooks.get(addr)
  if k=='date':cpu.reg_write(UC_ARM64_REG_X0,META)
  elif k=='value':cpu.reg_write(UC_ARM64_REG_D0,struct.unpack('<Q',struct.pack('<d',self.getdouble(cpu.reg_read(UC_ARM64_REG_X20))))[0])
  else:return super().hook(cpu,addr,size,data)
  cpu.reg_write(UC_ARM64_REG_PC,cpu.reg_read(UC_ARM64_REG_LR))
 def run(self,*,now=1000.,last=-1.,new=False,active=False,delayed=False,intensity=0.,fast=.04,slow=.1):
  cpu=self.cpu;cpu.mem_write(STACK,bytes(0x10000));cpu.mem_write(OUT,bytes(64))
  self.putdouble(FILTER+0x10,slow);self.putdouble(FILTER+0x18,fast);self.putdouble(OBJ+0x128,last)
  self.putdouble(MOV,now);self.putdouble(MOV+8,99.);cpu.mem_write(MOV+48,bytes([new,active,delayed]));self.putdouble(MOV+56,intensity)
  for r,p in [(UC_ARM64_REG_SP,STACK+0x8000),(UC_ARM64_REG_X0,MOV),(UC_ARM64_REG_X8,OUT),(UC_ARM64_REG_X20,OBJ),(UC_ARM64_REG_LR,STOP)]:cpu.reg_write(r,p)
  cpu.emu_start(BASE+0x9a704,STOP,count=10000);assert cpu.reg_read(UC_ARM64_REG_PC)==STOP
  return dict(new=bool(cpu.mem_read(OUT+48,1)[0]),active=bool(cpu.mem_read(OUT+49,1)[0]),delayed=bool(cpu.mem_read(OUT+50,1)[0]),intensity=self.getdouble(OUT+56),duration=self.getdouble(OUT+8),last=self.getdouble(OBJ+0x128),date=self.getdouble(OUT))
def expected_filter(c):
 return armed_filter(**c)
def main():
 args=probe_arguments(__doc__, 'watch-armed-filter-proof.json')
 p=FilterProbe(args.watch_binary);cases=[]
 for delayed in [False,True]:
  threshold=.1 if delayed else .04
  for intensity in [threshold-1e-9,threshold,threshold+1e-9]:
   for last in [-1.,990.,989.999999,999.]:
    for new in [False,True]:
     case=dict(active=True,delayed=delayed,intensity=intensity,last=last,new=new);a=p.run(**case);e=expected_filter(case);assert a==e,(case,a,e);cases.append(dict(input=case,result=a))
 for fast,slow in [(1.,1.),(1.,.1),(.04,1.)]:
  for active in [False,True]:
   for new in [False,True]:
    for delayed in [False,True]:
     case=dict(fast=fast,slow=slow,active=active,new=new,delayed=delayed,intensity=.2);a=p.run(**case);e=expected_filter(case);assert a==e,(case,a,e);cases.append(dict(input=case,result=a))
 out={'scope':'Original complete ARM64 extendedFilterForArmedPhase instructions at 0x10009a704, with Date, Swift metadata/copy and logging shims. Synthetic movement input and field offsets; no sensor hardware or app scheduling.','binarySHA256':hashlib.sha256(p.blob).hexdigest(),'casesPassed':len(cases),'cases':cases}
 args.output.write_text(json.dumps(out,indent=2));print(json.dumps({'casesPassed':len(cases)}))
if __name__=='__main__':main()
