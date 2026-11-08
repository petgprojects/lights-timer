#!/usr/bin/env python3
"""Execute original watch event-rate and recursive calibration search instructions.
Uses native Swift-array fixture and supplied session effectiveEnd Date.
"""
from WatchArmedFilterProbe import *
from WatchAlgorithmReference import historical_movement_rate, calibrate_movement_filters
SESSION=DATA+0xa000;ARRAY=DATA+0xb000;EVENTS=DATA+0xc000
class HistoryProbe(FilterProbe):
 def __init__(self,watch_binary):
  super().__init__(watch_binary);self.put64(BASE+0x230860,STUB);self.put64(VWT+0x40,8);self.put64(OBJ+0x10,SESSION)
  for off,val in [(0x24dc58,0x100),(0x24dca8,0x110),(0x24dc38,0x10),(0x24dc40,0x18),(0x24dc48,0x20)]:self.put64(BASE+off,val)
  self.put64(SESSION+0x110,ARRAY)
  self.hooks.update({BASE+0x8da78:'enddate',BASE+0x1c7cb0:'noop',BASE+0x1c7c98:'noop',BASE+0x1c7f2c:'noop',BASE+0x1c7f44:'noop',BASE+0x291cc:'filtermetadata',BASE+0x1c7eb4:'stackobject'})
  self.ratecalls=0
 def hook(self,cpu,addr,size,data):
  if addr==BASE+0x8bbf4:self.ratecalls+=1
  k=self.hooks.get(addr)
  if k=='enddate':self.putdouble(cpu.reg_read(UC_ARM64_REG_X8),self.end)
  elif k=='filtermetadata':cpu.reg_write(UC_ARM64_REG_X0,DATA+0x90000)
  elif k=='stackobject':cpu.reg_write(UC_ARM64_REG_X0,self.x(1))
  else:return super().hook(cpu,addr,size,data)
  cpu.reg_write(UC_ARM64_REG_PC,cpu.reg_read(UC_ARM64_REG_LR))
 def prepare(self,start,end,events):
  self.end=end;self.putdouble(SESSION+0x100,start);self.put64(ARRAY+0x10,len(events));self.ratecalls=0
  for i,(date,kind,intensity) in enumerate(events):
   p=EVENTS+i*0x40;self.put64(ARRAY+0x20+i*8,p);self.putdouble(p+0x10,date);self.cpu.mem_write(p+0x18,bytes([kind]));self.putdouble(p+0x20,intensity)
 def execute(self,addr):
  self.cpu.reg_write(UC_ARM64_REG_SP,STACK+0xe000);self.cpu.reg_write(UC_ARM64_REG_X20,OBJ);self.cpu.reg_write(UC_ARM64_REG_LR,STOP)
  self.cpu.emu_start(BASE+addr,STOP,count=1000000);assert self.cpu.reg_read(UC_ARM64_REG_PC)==STOP
  return struct.unpack('<d',struct.pack('<Q',self.cpu.reg_read(UC_ARM64_REG_D0)))[0]
 def rate(self,start,end,events,fast,slow):
  self.prepare(start,end,events);self.putdouble(FILTER+0x10,slow);self.putdouble(FILTER+0x18,fast);self.cpu.reg_write(UC_ARM64_REG_X0,FILTER)
  return self.execute(0x8bbf4)
 def search(self,start,end,events,target):
  self.prepare(start,end,events);self.cpu.reg_write(UC_ARM64_REG_X0,0)
  for reg,v in [(UC_ARM64_REG_D0,0.),(UC_ARM64_REG_D1,2.),(UC_ARM64_REG_D2,target)]:self.cpu.reg_write(reg,struct.unpack('<Q',struct.pack('<d',v))[0])
  result=self.execute(0x8ca8c);assert self.ratecalls==41,self.ratecalls;return result

def rate_expected(start,end,events,fast,slow):
 return historical_movement_rate(start,end,events,fast,slow)
def search_expected(start,end,events,target):
 return calibrate_movement_filters(start,end,events,target)['midpoint']

def main():
 args=probe_arguments(__doc__, 'watch-history-calibration-proof.json')
 p=HistoryProbe(args.watch_binary);rates=[];searches=[]
 for duration in [0,3600,10800,14400,18000,28800]:
  start=100.;end=start+duration;cutoff=max(start,min(start+7200,end-10800))
  events=[(cutoff-1e-6,1,.5),(cutoff,1,.04),(cutoff+1e-6,1,.039999999),(cutoff,2,.1),(cutoff,2,.099999999),(end+1,1,.5),(cutoff,0,10),(cutoff,3,10)]
  for fast,slow in [(.04,.1),(.040000001,.100000001),(0.,0.),(1.,1.)]:
   a=p.rate(start,end,events,fast,slow);e=rate_expected(start,end,events,fast,slow);assert a==e,(duration,a,e)
   rates.append(dict(start=start,end=end,cutoff=cutoff,events=events,fast=fast,slow=slow,result=a))
 # Replay the actual recursive search AND rate routine, not a stubbed rate oracle.
 start=100.;end=28900.;events=[(8000+i*600,(i%2)+1,.02+i*.025) for i in range(30)]
 for target in [0.,.1,1.,2.,3.,5.,9.5,11.,20.]:
  a=p.search(start,end,events,target);e=search_expected(start,end,events,target);assert a==e,(target,a,e)
  searches.append(dict(target=target,midpoint=a,slow=min(a,1),fast=max(a-1,0),rateEvaluations=p.ratecalls))
 out={'scope':'Complete original ARM64 event-rate 0x10008bbf4 and recursive calibration search 0x10008ca8c instructions. Framework Date/Swift allocation/refcount/exclusivity shims; session effectiveEnd supplied, not evaluated. Native-array fixtures include cutoff/intensity boundaries and future-date behavior.','binarySHA256':hashlib.sha256(p.blob).hexdigest(),'checksPassed':len(rates)+len(searches),'rateCases':rates,'searchFixture':dict(start=start,end=end,events=events),'searchCases':searches}
 args.output.write_text(json.dumps(out,indent=2));print(json.dumps({'checksPassed':len(rates)+len(searches),'rateCases':len(rates),'searchCases':len(searches)}))
if __name__=='__main__':main()
