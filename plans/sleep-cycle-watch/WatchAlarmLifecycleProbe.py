#!/usr/bin/env python3
"""Execute watch alarm entry guards, runtime-expiration predicate and dispatcher.

Runs original 0x99334 including 0x36e74, and original dispatcher 0x9af74 with
original movement filter and alarm decision. Phase-change callback supplies the
separately tested calibration result; it is not part of this probe's coverage.
Foundation/Combine/Notification/Swift runtime accesses are synthetic fixtures.
"""
from WatchArmedFilterProbe import *
from WatchAlgorithmReference import alarm_rule
OPTIONALMETA=DATA+0x30000;OPTIONALVWT=DATA+0x30100
TUPLEVWT=DATA+0x30200;DECVWT=DATA+0x30300;OPTIONALDECMETA=DATA+0x30400;OPTIONALDECVWT=DATA+0x30500
RUNTIMESELF=DATA+0x31000;RUNTIME=DATA+0x32000;NSDATE=DATA+0x33000
class LifecycleProbe(FilterProbe):
 def __init__(self,watch_binary):
  super().__init__(watch_binary)
  self.put64(BASE+0x230860,STUB);self.put64(VWT+0x40,8)
  self.put64(OPTIONALMETA-8,OPTIONALVWT);self.put64(OPTIONALVWT+0x40,16)
  self.put64(TUPLEMETA-8,TUPLEVWT);self.put64(TUPLEVWT+0x40,32)
  self.put64(DEC-8,DECVWT);self.put64(DECVWT+0x40,64);self.put64(DECVWT+0x30,STUB+8);self.put64(DECVWT+0x38,STUB+12)
  self.put64(OPTIONALDECMETA-8,OPTIONALDECVWT);self.put64(OPTIONALDECVWT+0x40,80)
  for addr,value in [(0x23d3b0,0x100),(0x240698,0x140),(0x2406a0,0x150),(0x2406e0,0x160)]:self.put64(BASE+addr,value)
  self.hooks.update({BASE+0x6ae8:'genericmeta',BASE+0x1c8064:'weakalarm',BASE+0x1c8028:'weakdelegate',BASE+0x1c7ddc:'keypath',BASE+0x1c4e48:'alarmdate',BASE+0x1c7f2c:'noop',BASE+0x1c7fe0:'noop',BASE+0x1c4920:'dategreater',BASE+0x1c8800:'expiration',BASE+0x1c7a88:'noop',BASE+0x1c4980:'datebridge',BASE+0x1c79e0:'noop',BASE+0x37c00:'optionalcopy',BASE+0x1c495c:'intervalnow',BASE+0x1c4494:'notification',BASE+0x1c7d10:'castmovement',BASE+0x8b8a0:'movementcopy',BASE+0x222fc:'noop',BASE+0x989f0:'phasechange'})
 def hook(self,cpu,addr,size,data):
  if addr==BASE+0x99334:self.decisioncalls+=1
  if addr==BASE+0x9a704:self.filtercalls+=1
  if addr==BASE+0x36e74:self.runtimecalls+=1
  k=self.hooks.get(addr)
  if k=='genericmeta':
   a=self.x(0);cpu.reg_write(UC_ARM64_REG_X0,TUPLEMETA if a==BASE+0x23d4f8 else OPTIONALDECMETA if a==BASE+0x23c798 else OPTIONALMETA)
  elif k=='weakalarm':cpu.reg_write(UC_ARM64_REG_X0,DATA+0x34000 if self.has_alarm else 0)
  elif k=='weakdelegate':cpu.reg_write(UC_ARM64_REG_X0,RUNTIMESELF if self.has_delegate else 0)
  elif k=='keypath':cpu.reg_write(UC_ARM64_REG_X0,DATA+0x35000)
  elif k=='alarmdate':
   p=cpu.reg_read(UC_ARM64_REG_X8);self.putdouble(p,self.deadline or 0.);cpu.mem_write(p+8,bytes([self.deadline is None]))
  elif k=='dategreater':cpu.reg_write(UC_ARM64_REG_X0,int(self.getdouble(self.x(0))>self.getdouble(self.x(1))))
  elif k=='expiration':cpu.reg_write(UC_ARM64_REG_X0,NSDATE if self.expiry is not None else 0)
  elif k=='datebridge':self.putdouble(cpu.reg_read(UC_ARM64_REG_X8),self.expiry)
  elif k=='intervalnow':cpu.reg_write(UC_ARM64_REG_D0,struct.unpack('<Q',struct.pack('<d',self.getdouble(cpu.reg_read(UC_ARM64_REG_X20))-self.wall_now))[0])
  elif k=='notification':self.put64(cpu.reg_read(UC_ARM64_REG_X8)+0x18,DEC if self.has_notification else 0)
  elif k=='castmovement':
   if self.cast_valid:cpu.mem_write(self.x(0),bytes(cpu.mem_read(MOV,64)))
   cpu.reg_write(UC_ARM64_REG_X0,int(self.cast_valid))
  elif k=='movementcopy':cpu.mem_write(self.x(1),bytes(cpu.mem_read(self.x(0),64)))
  elif k=='gettag' and self.x(2)==DEC:cpu.reg_write(UC_ARM64_REG_X0,cpu.mem_read(self.x(0)+64,1)[0])
  elif k=='settag' and self.x(3)==DEC:cpu.mem_write(self.x(0)+64,bytes([self.x(1)]))
  elif k=='phasechange':
   phase=self.x(0);cpu.mem_write(OBJ+0x28,bytes([phase]));self.transitions.append(phase)
   if phase==2:cpu.mem_write(OBJ+0x160,b'\x00');self.putdouble(OBJ+0x128,-1.)
  elif k=='fire':self.fires+=1;cpu.mem_write(OBJ+0x160,b'\x01')
  else:return super().hook(cpu,addr,size,data)
  cpu.reg_write(UC_ARM64_REG_PC,cpu.reg_read(UC_ARM64_REG_LR))
 def run(self,*,dispatch=False,now=1000.,deadline=1300.,window=600.,last=None,new=False,active=False,delayed=False,intensity=0.,sensitive=False,has_alarm=True,has_delegate=True,has_runtime=True,expiry=None,wall_now=1000.,phase=2,fired=False,armed=700.,prearmed=700.,last_tick=-1.,fast=0.,slow=0.,has_notification=True,cast_valid=True):
  cpu=self.cpu;cpu.mem_write(STACK,bytes(0x10000));self.fires=self.decisioncalls=self.filtercalls=self.runtimecalls=0;self.transitions=[]
  self.has_alarm=has_alarm;self.has_delegate=has_delegate;self.expiry=expiry;self.deadline=deadline;self.wall_now=wall_now;self.has_notification=has_notification;self.cast_valid=cast_valid
  self.put64(RUNTIMESELF+0x100,RUNTIME if has_runtime else 0)
  self.putdouble(OBJ+0x30,window);cpu.mem_write(OBJ+0x100,bytes([sensitive]));self.putdouble(OBJ+0x108,last or 0.);cpu.mem_write(OBJ+0x110,bytes([last is None]))
  cpu.mem_write(OBJ+0x28,bytes([phase]));cpu.mem_write(OBJ+0x160,bytes([fired]));self.putdouble(OBJ+0x128,last_tick)
  for off,date in [(0x140,armed),(0x150,prearmed)]:self.putdouble(OBJ+off,date or 0.);cpu.mem_write(OBJ+off+8,bytes([date is None]))
  self.putdouble(FILTER+0x10,slow);self.putdouble(FILTER+0x18,fast)
  self.putdouble(MOV,now);cpu.mem_write(MOV+48,bytes([new,active,delayed]));self.putdouble(MOV+56,intensity)
  for reg,value in [(UC_ARM64_REG_SP,STACK+0xe000),(UC_ARM64_REG_X20,OBJ),(UC_ARM64_REG_X0,MOV),(UC_ARM64_REG_LR,STOP)]:cpu.reg_write(reg,value)
  try:cpu.emu_start(BASE+(0x9af74 if dispatch else 0x99334),STOP,count=100000)
  except Exception as ex:raise RuntimeError(f'PC={cpu.reg_read(UC_ARM64_REG_PC):x}') from ex
  assert cpu.reg_read(UC_ARM64_REG_PC)==STOP
  return dict(fire=bool(self.fires),last=None if cpu.mem_read(OBJ+0x110,1)[0] else self.getdouble(OBJ+0x108),phase=cpu.mem_read(OBJ+0x28,1)[0],fired=bool(cpu.mem_read(OBJ+0x160,1)[0]),lastTick=self.getdouble(OBJ+0x128),transitions=self.transitions,decisionCalls=self.decisioncalls,filterCalls=self.filtercalls,runtimeCalls=self.runtimecalls)
def expected(c):
 now=c.get('now',1000.);deadline=c.get('deadline',1300.);last=c.get('last');phase=c.get('phase',2);fired=c.get('fired',False);tick=c.get('last_tick',-1.);transitions=[];fire=False;decisions=filters=runtimes=0
 new=c.get('new',False);active=c.get('active',False);delayed=c.get('delayed',False);intensity=c.get('intensity',0.)
 check=True
 if c.get('dispatch',False):
  if not c.get('has_notification',True) or not c.get('cast_valid',True) or phase==0:check=False
  if check:
   if phase==1 and c.get('prearmed',700.) is not None and now>c.get('prearmed',700.):phase=3;transitions.append(3)
   if phase==1:check=False
  if check and phase==3:
   if c.get('armed',700.) is not None and now>c.get('armed',700.):phase=2;transitions.append(2);fired=False;tick=-1.
   if phase==3:check=False
  if check and fired:check=False
  if check:
   filters=1;f=armed_filter(now=now,last=tick,new=new,active=active,delayed=delayed,intensity=intensity,fast=c.get('fast',0.),slow=c.get('slow',0.));new=f['new'];active=f['active'];tick=f['last']
 if check:
  decisions=1
  if c.get('has_alarm',True) and deadline is not None:
   if c.get('has_delegate',True):runtimes=1
   expires=c.get('expiry')
   force=c.get('has_delegate',True) and c.get('has_runtime',True) and expires is not None and expires-c.get('wall_now',1000.)<300
   if force or now>deadline:fire=True
   else:
    result=alarm_rule(now=now,deadline=deadline,window=c.get('window',600.),last=last,new=new,active=active,delayed=delayed,intensity=intensity,sensitive=c.get('sensitive',False));fire=result['fire'];last=result['last']
  fired=fired or fire
 return dict(fire=fire,last=last,phase=phase,fired=fired,lastTick=tick,transitions=transitions,decisionCalls=decisions,filterCalls=filters,runtimeCalls=runtimes)
def main():
 args=probe_arguments(__doc__,'watch-alarm-lifecycle-proof.json');p=LifecycleProbe(args.watch_binary);cases=[]
 def test(name,**c):
  a=p.run(**c);e=expected(c);assert a==e,(name,c,a,e);cases.append(dict(name=name,input=c,result=a))
 for delta in [-1e-6,0.,1e-6]:test(f'deadline_{delta}',now=1300.+delta)
 for remaining in [-1.,0.,299.999999,300.,300.000001,1000.]:test(f'expiration_{remaining}',expiry=1000.+remaining)
 for has_alarm in [False,True]:
  for deadline in [None,900.]:
   for has_delegate in [False,True]:test('missing_alarm_or_deadline',has_alarm=has_alarm,deadline=deadline,has_delegate=has_delegate,expiry=1001.)
 for has_delegate in [False,True]:
  for has_runtime in [False,True]:test('missing_runtime',has_delegate=has_delegate,has_runtime=has_runtime,expiry=1001.)
 for phase in range(4):
  for delta in [-1e-6,0.,1e-6]:
   for fired in [False,True]:test(f'phase_{phase}_delta_{delta}_fired_{fired}',dispatch=True,phase=phase,now=700.+delta,fired=fired)
 for prearmed,armed in [(None,700.),(700.,None),(699.,701.),(701.,699.)]:test('phase_dates',dispatch=True,phase=1,prearmed=prearmed,armed=armed,now=700.)
 for has_notification,cast_valid in [(False,True),(True,False)]:test('notification_missing_or_wrong_type',dispatch=True,has_notification=has_notification,cast_valid=cast_valid)
 for now in [1299.999999,1300.,1300.000001]:test('dispatcher_deadline',dispatch=True,phase=1,now=now)
 for active in [False,True]:test('dispatcher_sensitive',dispatch=True,phase=1,active=active,intensity=.5,sensitive=True)
 out={'scope':__doc__,'binarySHA256':hashlib.sha256(p.blob).hexdigest(),'casesPassed':len(cases),'cases':cases}
 args.output.write_text(json.dumps(out,indent=2));print(json.dumps({'casesPassed':len(cases)}))
if __name__=='__main__':main()
