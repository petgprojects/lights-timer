#!/usr/bin/env python3
"""Executes the actual watch alarm-window parameter selection basic blocks."""
from pathlib import Path
from WatchProbeSupport import read_arm64, probe_arguments
from WatchAlgorithmReference import alarm_window_parameters
import struct,json,hashlib
from unicorn import Uc,UC_ARCH_ARM64,UC_MODE_ARM
from unicorn.arm64_const import UC_ARM64_REG_X20,UC_ARM64_REG_SP,UC_ARM64_REG_PC
R=Path(__file__).parent;B=0x10000000;D=0x20000000;S=0x30000000
args=probe_arguments(__doc__, 'watch-alarm-parameter-proof.json')
blob=read_arm64(args.watch_binary);cpu=Uc(UC_ARCH_ARM64,UC_MODE_ARM)
for a,n in [(B,0x400000),(D,0x1000),(S,0x10000)]:cpu.mem_map(a,n)
cpu.mem_write(B,blob)
for p,v in [(B+0x2406c0,0x100),(B+0x2406c8,0x108)]:cpu.mem_write(p,struct.pack('<Q',v))
cases=[]
for secs in [0,7200]+[lim*60+epsilon for lim in [10,15,20,30,45,60,90] for epsilon in [-.001,0,.001]]:
 cpu.mem_write(D+0x30,struct.pack('<d',secs));cpu.reg_write(UC_ARM64_REG_SP,S+0x8000);cpu.reg_write(UC_ARM64_REG_X20,D)
 cpu.emu_start(B+0x9c03c,B+0x9c180,count=1000)
 assert cpu.reg_read(UC_ARM64_REG_PC)==B+0x9c180
 actual=struct.unpack('<2d',cpu.mem_read(D+0x100,16));assert actual==alarm_window_parameters(secs),(secs,actual)
 cases.append({'windowSeconds':secs,'windowMinutes':secs/60,'regularThreshold':actual[0],'maxThreshold':actual[1]})
out={'scope':'Original watch ARM64 instructions 0x10009C03C through 0x10009C17C; stopped before logging. Only runtime field-offset globals supplied; no algorithm stubs.','binarySHA256':hashlib.sha256(blob).hexdigest(),'checksPassed':len(cases),'cases':cases}
args.output.write_text(json.dumps(out,indent=2));print(json.dumps({'checksPassed':len(cases)}))
