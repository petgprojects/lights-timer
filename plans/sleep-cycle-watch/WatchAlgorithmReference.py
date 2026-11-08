#!/usr/bin/env python3
"""Independent reconstruction of the verified Sleep Cycle watch arithmetic.

This is a research reference, not a clinical sleep-stage classifier or an app
integration. Inputs represent already acquired raw accelerometer vectors and
already decorated movement events. See README.md for call-path provenance and
watch-proof.json for comparison coverage against original machine instructions.
"""
import math


class FastMovementAnalyzer:
    """Sample-count motion detector; timestamps are seconds and vectors are XYZ.

    The live dLimit can change; the delayed threshold remains the value derived
    at construction. Nonoverlapping means complete every 301 input samples.
    """

    def __init__(self, limit=0.09000000000000001):
        self.limit = limit
        self.threshold = (2.1 if limit < .04 else 1) * math.exp((limit - .327) / .043)
        self.prev = self.long = self.avg = None
        self.buf = []
        self.counter = 0
        self.last = None

    def update(self, t, vector):
        new = active = delayed = False
        intensity = 0.
        if self.prev is not None:
            intensity = math.dist(self.prev, vector)
            delta = max(intensity, 0 if self.long is None else math.dist(self.long, vector))
            if delta > self.limit:
                active = True
                new = self.last is None
                intensity = delta
        self.buf.append(vector)
        if len(self.buf) == 301:
            mean = tuple(sum(p[k] for p in self.buf) / 301 for k in range(3))
            if self.avg is not None:
                delta = max(abs(a - b) for a, b in zip(mean, self.avg))
                if delta > self.threshold:
                    active = delayed = True
                    new = self.last is None
                    intensity = delta
            self.avg = mean
            self.buf = []
        if active:
            self.last = t
        elif self.last is not None and t - self.last > 10:
            self.last = None
        self.prev = vector
        if self.counter % 100 == 0:
            self.long = vector
        self.counter += 1
        return dict(new=new, inProgress=active, delayed=delayed,
                    intensity=intensity, counter=self.counter,
                    historyIndex=len(self.buf), lastActiveTime=self.last)


def alarm_window_parameters(window_seconds):
    """Return regular and maximum target movement rates, in events/hour."""
    minutes = window_seconds / 60
    for limit, pair in [(10, (8.5, 11)), (15, (8, 10.5)), (20, (7.5, 10)),
                        (30, (7, 9.5)), (45, (6, 8.5)), (60, (5.5, 7)),
                        (90, (5, 6.5))]:
        if minutes <= limit:
            return pair
    return 7, 9.5


def alarm_rule(*, now=1000., deadline=1300., window=600., last=None,
               new=False, active=False, delayed=False, intensity=0., sensitive=False):
    """Decision core after valid-alarm, deadline and delegate-override guards.

    last is this alarm rule's qualifying movement start, not the motion
    analyzer's last-active timestamp. Caller must supply a positive window.
    """
    if sensitive:
        return dict(fire=active, last=last)
    elapsed = math.inf if last is None else now - last
    if new:
        scaled = (1 - (deadline - now) / window) * intensity
        qualifies = scaled > .02
        return dict(fire=qualifies and elapsed < 120, last=now if qualifies else last)
    if delayed and intensity > .1 and last is None:
        return dict(fire=False, last=now)
    return dict(fire=active and not delayed and elapsed > 10 and math.isfinite(elapsed), last=last)


def armed_filter(*, now=1000., last=-1., new=False, active=False, delayed=False,
                 intensity=0., fast=.04, slow=.1):
    """Apply calibrated dLimit/raLimit and regroup accepted movement events."""
    if active and not (fast == 1 and slow == 1):
        if intensity >= (slow if delayed else fast):
            new = now - last > 10 or last == -1.
            last = now
        else:
            new = active = False
    return dict(new=new, active=active, delayed=delayed, intensity=intensity,
                duration=0., last=last, date=now)


def historical_movement_rate(start, end, events, fast, slow):
    """events is [(timestamp, kind, intensity)]; kinds 1 and 2 qualify.

    end is the session's effective end supplied by its surrounding lifecycle.
    This routine has no separate event timestamp <= end condition.
    """
    cutoff = max(start, min(start + 7200, end - 10800))
    count = sum(kind in (1, 2) and date >= cutoff
                and intensity >= (fast if kind == 1 else slow)
                for date, kind, intensity in events)
    return count / ((end - cutoff) / 60 / 60) if end != cutoff else 9.5


def calibrate_movement_filters(start, end, events, target):
    """41 binary-search rate evaluations, then the next midpoint is returned."""
    low, high = 0., 2.
    for _ in range(41):
        mid = low + (high - low) * .5
        rate = historical_movement_rate(start, end, events, max(mid - 1, 0), min(mid, 1))
        if target <= rate:
            low = mid
        else:
            high = mid
    mid = low + (high - low) * .5
    return dict(midpoint=mid, slow=min(mid, 1), fast=max(mid - 1, 0))


# Full alarm lifecycle reconstruction, independently traced by the alarm analysis.
from dataclasses import dataclass, replace
from math import inf, nan
from sys import float_info

@dataclass(frozen=True)
class Movement:
    date: float
    new: bool
    active: bool
    delayed: bool
    intensity: float
    duration: float = 0.0

@dataclass(frozen=True)
class Event:
    date: float
    kind: int  # 1=instantaneous movement; 2=delayed block movement
    intensity: float

@dataclass(frozen=True)
class Filter:
    ra: float = 0.0  # delayed movement threshold
    d: float = 0.0   # instantaneous movement threshold


def effective_end(start, session_end, events):
    """SleepSessionWatch accessor 0x10008da78."""
    return session_end if session_end is not None else max((e.date for e in events), default=start)


def movements_per_hour(start, session_end, events, filt=Filter()):
    """SleepSessionOperations 0x10008bbf4; no explicit upper date bound."""
    end = effective_end(start, session_end, events)
    cutoff = max(start, min(start + 7200.0, end - 10800.0))
    hours = ((end - cutoff) / 60.0) / 60.0
    count = sum(e.date >= cutoff and (
        e.kind == 1 and e.intensity >= filt.d or
        e.kind == 2 and e.intensity >= filt.ra)
        for e in events)
    return 9.5 if hours == 0.0 else count / hours


def parameter_pair(window_seconds):
    """setupWakeUpParameters 0x10009c03c; inclusive upper bounds."""
    minutes = window_seconds / 60.0
    for upper, regular, maximum in ((10, 8.5, 11), (15, 8, 10.5),
        (20, 7.5, 10), (30, 7, 9.5), (45, 6, 8.5),
        (60, 5.5, 7), (90, 5, 6.5)):
        if minutes <= upper:
            return regular, maximum
    return 7.0, 9.5


def scalar_filter(x):
    return Filter(min(x, 1.0), x - 1.0 if x >= 1.0 else 0.0)


def calculate_filter(target, start, session_end, events):
    """0x10008c6e8 and recursive bisection 0x10008ca8c."""
    duration = max(0.0, effective_end(start, session_end, events) - start)
    if duration / 3600.0 < 2.0:
        return Filter()
    if movements_per_hour(start, session_end, events) < target:
        return Filter()
    return scalar_filter(search_scalar(target, start, session_end, events))


def search_scalar(target, start, session_end, events):
    """The recursive helper; caller applies the duration/rate guards above."""
    low, high = 0.0, 2.0
    for _ in range(41):
        mid = low + (high - low) * 0.5
        if target <= movements_per_hour(start, session_end, events, scalar_filter(mid)):
            low = mid
        else:
            high = mid
    return low + (high - low) * 0.5


def divide_ieee(a, b):
    if b == 0.0:
        return nan if a == 0.0 else (inf if a > 0.0 else -inf)
    return a / b


class AlarmRules:
    """Exact valid-input decision graph, excluding platform APIs and logging."""
    def __init__(self, alarm_time, window_seconds, start, events, session_end=None):
        self.alarm_time, self.window = alarm_time, window_seconds
        self.start, self.events, self.session_end = start, events, session_end
        self.phase = 0  # noAlarm=0, sleepy=1, armed=2, preArmed=3
        self.sensitive = False
        self.filt = Filter()
        self.last_start = None
        self.last_qualified_tick = -1.0
        self.fired = False
        self.begin()

    def begin(self):
        # 0x10009c2cc and 0x10009b4ec
        self.armed_time = self.alarm_time - self.window
        self.prearmed_time = self.armed_time
        self.last_start = None
        self.phase = 1

    def arm(self):
        # changePhaseTo(.armedPhase), 0x1000989f0
        self.phase = 2
        self.fired = False
        rate = movements_per_hour(self.start, self.session_end, self.events)
        regular, maximum = parameter_pair(self.window)
        self.sensitive = rate < regular
        self.filt = calculate_filter(maximum, self.start, self.session_end, self.events) if rate > maximum else Filter()
        self.last_qualified_tick = -1.0

    def filter_movement(self, movement):
        # extendedFilterForArmedPhase, 0x10009a704
        if not movement.active or self.filt == Filter(1.0, 1.0):
            return replace(movement, duration=0.0)
        threshold = self.filt.ra if movement.delayed else self.filt.d
        if not threshold <= movement.intensity:
            return replace(movement, new=False, active=False, duration=0.0)
        previous = self.last_qualified_tick
        self.last_qualified_tick = movement.date
        return replace(movement, new=(movement.date - previous > 10.0 or previous == -1.0), duration=0.0)

    def check(self, movement, force_runtime=False):
        # checkIfAlarmShouldGoOff, 0x100099334. Called after filter.
        if force_runtime or movement.date > self.alarm_time:
            self.fired = True
            return 'runtime_limit' if force_runtime else 'deadline'
        if self.sensitive:
            if movement.active:
                self.fired = True
                return 'sensitive_movement'
            return None
        elapsed = float_info.max if self.last_start is None else movement.date - self.last_start
        if movement.new:
            progress = 1.0 - divide_ieee(self.alarm_time - movement.date, self.window)
            if progress * movement.intensity > 0.02:
                reason = None
                if elapsed < 120.0:
                    self.fired = True
                    reason = 'two_qualifying_movements'
                self.last_start = movement.date
                return reason
            return None
        if movement.delayed and movement.intensity > 0.1 and self.last_start is None:
            self.last_start = movement.date
            return None
        if not movement.delayed and movement.active and 10.0 < elapsed < float_info.max:
            self.fired = True
            return 'continued_movement'
        return None

    def receive(self, movement, force_runtime=False):
        # notification dispatch 0x10009af74
        if self.phase == 0:
            return None
        if self.phase == 1 and movement.date > self.prearmed_time:
            self.phase = 3
        if self.phase == 1:
            return None
        if self.phase == 3 and movement.date > self.armed_time:
            self.arm()
        if self.phase == 3 or self.fired:
            return None
        return self.check(self.filter_movement(movement), force_runtime)


def detector_d_limit():
    """Actual watch getter 0x10002bd20; no preference or phase input."""
    return 0.09000000000000001


class RecorderEventBinner:
    """Recorder event-bin reconstruction (statically traced, not emulated here).

    Each query starts its local boundary at query_start + 60. Detector state
    and pending last intensity of each category persist across query calls.
    No resampling: feed every raw recorded XYZ sample into the detector.
    """
    def __init__(self, analyzer=None):
        self.analyzer = analyzer or FastMovementAnalyzer(detector_d_limit())
        self.pending_fast = self.pending_slow = None

    def process_query(self, query_start, samples):
        boundary = query_start + 60.
        events = []
        for timestamp, vector in samples:
            movement = self.analyzer.update(timestamp, vector)
            if timestamp > boundary:
                if self.pending_slow is not None:
                    events.append(Event(boundary, 2, self.pending_slow))
                if self.pending_fast is not None:
                    events.append(Event(boundary, 1, self.pending_fast))
                self.pending_fast = self.pending_slow = None
                boundary += 60.  # Exactly one step even after a long data gap.
            if movement['inProgress']:
                if movement['delayed']:
                    self.pending_slow = movement['intensity']
                else:
                    self.pending_fast = movement['intensity']
        return events  # No trailing partial-bin flush.
