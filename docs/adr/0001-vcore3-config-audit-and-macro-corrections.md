# ADR-0001: VCore 3.1 Configuration Audit and Macro Corrections

## Status

Accepted

## Date

2026-02-22

## Context

The VCore 3.1 CoreXY AWD printer running Kalico (Klipper fork) had accumulated configuration drift across ~90 cfg files over multiple hardware revisions (VZ toolhead to Wishbone, Goliath to Chube Conduction hotend, addition of Happy Hare MMU, migration from RatOS hooks to custom PRINT_START/PRINT_END). No systematic audit had been performed since the initial build.

### System Overview

| Component | Detail |
|-----------|--------|
| Frame | RatRig VCore 3.1 (~300mm) |
| Kinematics | CoreXY AWD (4 XY motors) |
| XY Motors | LDO 42STH60-3004AH on TMC5160 @ 48V, 2.6A |
| Z Motors | LDO 42STH48-2504AC on TMC2209 @ 24V, 1.5A |
| Main MCU | BTT Octopus Max EZ V1.0 (STM32H723) |
| Toolboard | EBB42 v1.2 (STM32G0B1) |
| Probe | Beacon RevH (contact mode) |
| Extruder | Bondtech LGX Pro Metal |
| Hotend | Chube Conduction (PT1000, max 400C) |
| MMU | Happy Hare on dedicated MCU |
| Firmware | Kalico (Klipper fork with danger_options, z_tilt_ng, motors_sync) |

## Decision

Perform a comprehensive four-domain audit and apply all fixes locally before pushing to the printer host.

### Audit Domains

1. **Steppers / TMC / Motion** - Pin assignments, driver settings, kinematics
2. **Macros / Print Flow** - PRINT_START/END, PAUSE/RESUME, heating logic, Jinja2 correctness
3. **Probe / Mesh / Thermal** - Beacon config, bed mesh bounds, z_tilt_ng, sensor assignments
4. **Fan / Hardware / Pins** - Pin conflicts, duplicate sections, peripheral safety

## Findings and Fixes Applied

### CRITICAL (8 issues - all fixed)

| # | File | Issue | Fix |
|---|------|-------|-----|
| C1 | `custom/tuning/tmc_autotune.cfg` | Missing `[motor_constants ldo-42sth48-2504ac]` - Z autotune would fail at startup | Added motor_constants section (resistance: 1.2, inductance: 0.0015, holding_torque: 0.55, max_current: 2.5) |
| C2 | `custom/macros/utils.cfg` | `_FALLBACK_PURGE` uses undefined variable `V` (was `vars`) and calls nonexistent `_GET_BED_BOUNDS` macro | Renamed to `V`, replaced `_GET_BED_BOUNDS` with `printer.toolhead.axis_minimum` lookups |
| C3 | `custom/macros/print.cfg` | `M600` sets `VARIABLE=m600` on RESUME which has no such variable | Removed the SET_GCODE_VARIABLE call (Happy Hare handles filament changes) |
| C4 | `custom/macros/heating_cooling.cfg` | `PREHEAT` calls `CHAMBER_FANS_OFF` which doesn't exist | Changed to `ALL_CHAMBER_FANS_OFF` |
| C5 | `custom/macros/print.cfg` | `CANCEL_PRINT` calls `HEATER_INTERRUPT` which doesn't exist | Removed the call (PRINT_END already handles heater shutdown) |
| C6 | `custom/macros/homing.cfg` | `MAYBE_HOME` uses `axesToHome` before initialization (`{% set axes = '' %}` was wrong var name) | Changed `axes` to `axesToHome` |
| C7 | `custom/macros/print.cfg` | Non-Beacon PREHEAT path passes `TARGET_CHAMBER=` instead of `TARGET_CHAMBER_TEMP=` | Fixed parameter name to match PREHEAT's expected param |
| C8 | `custom/macros/dynamic_macros/toolhead_assisted_chamber_heating.cfg` | `TA_CHAMBER_HEAT` defaults to `vars.extruder_temp` which doesn't exist in `_PRINTER_VARS` | Changed to `vars.default_chamber_assist_extruder_temp` |

### WARNING (12 issues - all fixed or documented)

| # | File | Issue | Fix |
|---|------|-------|-----|
| W1 | `printer.cfg` | Duplicate `variable_default_chamber_target: 40` (lines 31 and 38) | Removed first occurrence |
| W2 | `custom/macros/print.cfg` | `SET_DISPLAY_TEXT` references undefined `{target_extruder}` | Changed to `{hotend_temp}` |
| W3 | `custom/macros/print.cfg` | PAUSE turns hotend fully off (`M104 S0`), ignoring `pause_standby_extruder_delta` and `pause_min_standby_temp` | Now calculates standby temp using those variables |
| W4 | `custom/macros/heating_cooling.cfg` | COOLDOWN_SEQUENCE references `vars.filter` (doesn't exist) instead of `vars.filter_fan` | Fixed to `vars.filter_fan` |
| W5 | `custom/macros/heating_cooling.cfg` | Message says "{duration} minutes" but value is in seconds (300s = 5min) | Fixed to `{(duration/60)\|int} minutes` |
| W6 | `custom/macros/print.cfg` | `SET_GCODE_OFFSET Z_ADJUST=0` is a no-op (adjusts by zero) | Removed the line |
| W7 | `custom/macros/ratos_overrides.cfg` | References 3 nonexistent macros: `MAYBE_START_CHAMBER_FANS`, `CHAMBER_FANS_STOP`, `RESTORE_CUSTOM_VARIABLE_DEFAULTS` | Replaced with `CHAMBER_FANS_ON`, `ALL_CHAMBER_FANS_OFF`, `RESET_TO_START_STATE` |
| W8 | `custom/macros/homing.cfg` | `_CENTER_AXIS` has redundant `if defined else same_var` conditional | Simplified to direct access |
| W9 | `custom/vcore3/vcore3.cfg` | Duplicate `[controller_fan controller_fan]` (PD8) conflicts with `controller_fans.cfg` (PA2) | Removed duplicate from vcore3.cfg (PA2 in controller_fans.cfg is the real one with tachometer) |
| W10 | `custom/vcore3/vcore3.cfg` | `[duplicate_pin_override]` references nonexistent aliases `therm_1, therm_2, therm_3` | Changed to `PB0` (the actual shared pin between motor_4 and water_temp sensors) |
| W11 | `custom/mcus/mmu_board.cfg` | Duplicate `sensor_mcu:` lines with different case (`MMU` vs `mmu`) | Removed the first (uppercase) line |
| W12 | `custom/macros/fans.cfg` | `FILTER_DELAYED_STOP` hardcodes `FAN=filter` instead of using `_PRINTER_VARS` | Changed to call `TURN_FILTER_OFF` macro |

### INFO (5 items - documented, no changes needed)

| # | Issue | Notes |
|---|-------|-------|
| I1 | TMC5160 run_current 2.6A is 86.7% of motor max (3.0A) | Aggressive but within spec. Monitor motor thermals in enclosed chamber. |
| I2 | Motion limits (800mm/s, 60000mm/s^2) are aggressive | Reasonable for AWD 48V with input shaper at 122.6Hz/81.8Hz. Actual print profiles use lower values. |
| I3 | `min_extrude_temp: 0` disables cold extrusion safety | Intentional for Happy Hare MMU loading/unloading. |
| I4 | `interpolate: True` with `microsteps: 64` provides minimal benefit | 64 microsteps already very fine; interpolation only gives 4x (to 256). Harmless but suboptimal. |
| I5 | Z microsteps: 64 gives 3200 steps/mm on leadscrew | Excessive for mechanical resolution of leadscrews. 16 or 32 would suffice. Consider reducing if MCU bandwidth is a concern. |

### Items Requiring Manual Verification

| # | Item | Action Required |
|---|------|-----------------|
| V1 | Z motor_constants values for LDO 42STH48-2504AC | Verify resistance/inductance/torque against your specific LDO datasheet variant |
| V2 | AWD direction pin polarity (X/X1, Y/Y1) | Confirm motor mounting orientation matches primary=inverted, secondary=non-inverted pattern |
| V3 | Beacon y_offset: 27.51 (Wishbone override) vs 20.70 (beacon.cfg) | Confirm 27.51 is correct for Wishbone toolhead; clean up stale value in beacon.cfg |
| V4 | z_tilt_ng probe points overridden in wishbone.cfg | Confirm the Wishbone points (10,0 / 152.5,250 / 295,0) are the intended active set |

## Consequences

### Positive

- Printer can now start without autotune crash (missing motor_constants)
- CANCEL_PRINT, M600, PREHEAT for low-temp materials, and MAYBE_HOME no longer crash
- PAUSE uses standby temp instead of fully cooling hotend (prevents heatbreak clogs)
- RatOS override hooks now call macros that actually exist
- Pin override matches actual shared pins in the config
- Consistent fan control through `_PRINTER_VARS` indirection

### Negative

- Z motor_constants values are estimated and need datasheet verification
- Some changes to macro behavior (PAUSE standby temp, ratos_overrides) may need tuning

### Risks

- **Z autotune motor_constants accuracy**: Incorrect values could lead to suboptimal Z motor tuning. Mitigated by `tuning_goal: silent` which is conservative.
- **PAUSE standby temp change**: Previous behavior (full off) was "safe" if wasteful. New standby behavior keeps heater on, which is better for print quality but maintains power draw during pause.

## Files Modified

```
printer.cfg                                              # Removed duplicate variable
custom/macros/utils.cfg                                  # Fixed _FALLBACK_PURGE, added blank line
custom/macros/print.cfg                                  # 6 fixes (M600, CANCEL, display, offset, PREHEAT param, PAUSE standby)
custom/macros/homing.cfg                                 # Fixed MAYBE_HOME variable init, simplified _CENTER_AXIS
custom/macros/heating_cooling.cfg                        # Fixed CHAMBER_FANS_OFF, filter var, message units
custom/macros/fans.cfg                                   # Fixed FILTER_DELAYED_STOP hardcoded name
custom/macros/ratos_overrides.cfg                        # Fixed 3 undefined macro references
custom/macros/dynamic_macros/toolhead_assisted_chamber_heating.cfg  # Fixed 2 undefined variable defaults
custom/tuning/tmc_autotune.cfg                           # Added missing Z motor_constants
custom/vcore3/vcore3.cfg                                 # Removed duplicate controller_fan, fixed pin override
custom/mcus/mmu_board.cfg                                # Removed duplicate sensor_mcu line
```

## References

- [Kalico Documentation](https://kalico.gg/)
- [Beacon3D Quickstart](https://docs.beacon3d.com/quickstart/)
- [BTT Octopus Max EZ Pinout](https://github.com/bigtreetech/Octopus-Max-EZ)
- [TMC Autotune for Klipper](https://github.com/andrewmcgr/klipper_tmc_autotune)
- [Happy Hare MMU](https://github.com/moggieuk/Happy-Hare)
- [YanceyA Beacon Thermal Expansion Compensation](https://github.com/YanceyA/Beacon_Thermal_Expansion_Compensation)
