# VCore 3.1 Klipper/Kalico Configuration

## Hardware
- VCore 3.1 CoreXY AWD (4 XY motors: stepper_x, x1, y, y1)
- BTT Octopus Max EZ V1.0 main MCU, EBB42 v1.2 toolboard
- TMC5160 @ 48V (XY), TMC2209 @ 24V (Z)
- Beacon RevH probe (contact mode, thermal expansion compensation)
- Happy Hare MMU (Tradrack 1.0e, 4 gates) on BTT MMB dedicated MCU
- EREC-style filament cutter on Tradrack, servo on BTT MMB PA2 (RGB port)
- Servo-deployed nozzle wiper

## Firmware
- Kalico (Klipper fork) with: z_tilt_ng, danger_options,
  minimum_cruise_ratio, limited_corexy. (`high_precision_step_compress`
  exists only as commented-out lines in
  `custom/vcore3/steppers/xy-awd/steppers.cfg` — not active.)
- motors_sync module active (`custom/tuning/motor_sync.cfg`); PRINT_START
  calls `SYNC_MOTORS`
- MPC extruder temp control (requires `MPC_CALIBRATE` on printer after deploy)
- Kalico-native Python macros: `gcode: !!include <file>.py` and `!`-prefixed
  Python lines are handled by Kalico itself (configfile getscript +
  gcode_macro Python templates providing emit/wait_moves/sleep/
  set_gcode_variable/respond_info/math). The old DynamicMacros plugin is
  unused and removed. Macros live in `custom/macros/dynamic_macros/`.

## Workflow
- Edit locally in this repo, then deploy via git: commit + push, then `git pull`
  in `/home/pi/printer_data/config` on the printer (it's a checkout of this repo
  with an automated-backup job — **never rsync/scp into it**, that dirties the
  tree and breaks the sync; `klipper-variables.cfg` is always locally modified
  there, never `reset --hard` over it).
  No automated tests — verify every change before deploy:
  1. Grep for stale variable references across `custom/` and `printer.cfg`
  2. Cross-reference `printer["gcode_macro X"].variable_name` against declarations
  3. Verify param chains (e.g., PREHEAT → TA_CHAMBER_HEAT)
- **Config sync**: Local repo and printer can diverge (automated backups,
  Mainsail edits). When debugging, always diff the relevant files between
  local and `pi@printer:/home/pi/printer_data/config/` first.

## Key Files
- `printer.cfg` — Main config with `_PRINTER_VARS` (all tunable settings)
- `custom/macros/print.cfg` — PRINT_START, PRINT_END, PAUSE, RESUME, CANCEL_PRINT, M600
- `custom/macros/heating_cooling.cfg` — PREHEAT, COOLDOWN_SEQUENCE
- `custom/macros/nozzle_cleaner.cfg` — CLEAN_NOZZLE, `_WIPER_VARS` (wiper coordinates/speeds)
- `custom/macros/dynamic_macros/` — Kalico-native Python macros; Toolhead-assisted
  chamber heating (TA_CHAMBER_HEAT; loop lives in `custom/macros/python/chamber_heating.py`)
- `custom/macros/thermal_expansion_compensation.cfg` — Beacon nozzle expansion
- `klipper-variables.cfg` — Persistent saved variables (SAVE_VARIABLE target)
- `mmu/base/mmu_macro_vars.cfg` — Happy Hare macro tuning (tip forming, parking, post-unload extension)
- `mmu/addons/mmu_erec_cutter.cfg` / `mmu_erec_cutter_hw.cfg` — EREC cutter servo config and action macro
- `docs/adr/` — Architecture Decision Records

## Naming Conventions
- Local variables: `snake_case` (e.g., `hotend_temp`, `travel_feedrate`)
- Params: `UPPER_SNAKE_CASE` (e.g., `params.HOTEND_TEMP`)
- Temperatures: `*_temp` suffix (never `_c`, `_target`)
- Feedrates (mm/min): `*_feedrate` suffix
- Speeds (mm/s): `*_speed` suffix (as stored in `_PRINTER_VARS`)

## Gotchas
- **Klipper G4**: Only `G4 P<milliseconds>` works. `G4 S<seconds>` is silently ignored.
- **Jinja2 scoping**: `{% set %}` inside `{% if %}` propagates to the outer
  scope in Klipper (unlike standard Jinja2, where it would create a shadow
  variable). Don't rely on the difference — prefer building strings and
  checking `|length` over boolean flags.
- **ACCEL_TO_DECEL**: Deprecated in Kalico. Use `MINIMUM_CRUISE_RATIO` instead.
- **z_tilt_ng**: Kalico replacement for z_tilt. Check `printer.z_tilt_ng` first, then
  fall back to `printer.z_tilt`.
- **Kalico Python macros**: files in `custom/macros/dynamic_macros/` use
  Kalico-native `!!include <file>.py` / `!`-prefix Python — not vanilla
  Klipper Jinja. Don't lint them as standard macros, and validate their
  Python against Kalico's `gcode_macro.py` helper API (emit, wait_moves,
  sleep, set_gcode_variable, respond_info, math, own_vars), not the old
  DynamicMacros plugin.
- **Saved variables**: Changing names in `klipper-variables.cfg` requires migrating
  the file on the printer. Don't rename `variable_*` in saved vars casually.
- **MMU saved vars live in `klipper-variables.cfg`, NOT `mmu/mmu_vars.cfg`**:
  Klipper allows only one `[save_variables]`. The active one is in
  `custom/default_includes.cfg` → `klipper-variables.cfg`. HH's own
  `[save_variables] filename: mmu/mmu_vars.cfg` is commented out in
  `mmu_macro_vars.cfg`, so **`mmu/mmu_vars.cfg` is an orphaned dead file** — HH
  never reads or writes it. All `mmu_selector_offsets`, `mmu_calibration_*`,
  `mmu_state_gate_*` etc. are in `klipper-variables.cfg`. This bit us once:
  calibrated selector offsets sat in the orphan while HH ran stale values from
  the active file, parking T0 on the endstop. Always grep
  `klipper-variables.cfg` for MMU state.
- **`printer['gcode'].commands['X']`**: Unstable internal API. Prefer
  `printer.configfile.config["gcode_macro X"] is defined` instead (see PRINT_START
  for the established pattern).
- **CLEAN_NOZZLE during PRINT_START**: Always pass `SKIP_HEATING=1` and restore
  the Beacon contact cal temp (`M104` + `TEMPERATURE_WAIT`) before `G28 Z METHOD=CONTACT`.
  Letting CLEAN_NOZZLE heat/cool independently destabilizes contact calibration.
- **COOLDOWN_SEQUENCE filter ordering**: `TURN_FILTER_ON` must come *before*
  `UPDATE_DELAYED_GCODE ID=FILTER_DELAYED_STOP`, and no `ALL_FANS_OFF` after it.
  Otherwise the delayed stop fires on an already-off fan.
- **Sub-config overwriting TMC UART pin**: Klipper merges duplicate sections last-definition-wins. If a sub-config included after your motor config redefines `[tmc2209 extruder]` with an unqualified `uart_pin: e_uart_pin`, and `e_uart_pin` is also defined on the main MCU board_pins (e.g. Octopus Motor3 slot = PG12), the pin silently resolves to the wrong MCU. Symptom: writes appear to work, all reads time out — identical to a hardware UART failure. Fix: qualify explicitly — `uart_pin: toolboard_t0:e_uart_pin`. When a setting seems correct but isn't taking effect, grep for the same section key in all included files.
- **Board pin aliases**: Always use `x_step_pin`, `y_uart_pin`, etc. from
  `octopus-max-ez.cfg` board_pins — never hardcode GPIO numbers for Octopus
  motor/endstop pins in stepper configs. Hardcoded pins silently break when a
  motor slot is reassigned. (Known debt: `custom/vcore3/steppers/z/steppers.cfg`
  still hardcodes its GPIOs.)
- **klippy.log has multiple sessions**: Search for `Start printer at` to find
  session boundaries. A config section or error in the log may be from an older
  boot, not the current one. Always confirm which session you're reading.
- **Klipper servo angle clamping**: `_get_pwm_from_angle` clamps to
  `[0, maximum_servo_angle]` silently. An angle of 225 with max 180 just
  produces the same pulse as 180. Increase `maximum_servo_angle` if you
  genuinely need a wider range, or fix the variable to the clamped value.
- **EREC cutter + loading**: `user_pre_load_extension` must be `"_CUTTER_CLOSE"`
  so the servo aligns the bowden before every load. Without it, a fresh load
  (no prior unload/cut) will fail because the servo is in an unknown position.
- **Happy Hare PAUSE/RESUME wrapping**: HH's Python module wraps PAUSE/RESUME
  as the outermost layer (saves original as `__PAUSE`/`__RESUME`). Our macros
  check `printer.mmu.enabled` and skip retraction/parking when HH is active
  to avoid double-actions. HH does NOT manage standby temp for user-initiated
  pauses — our macros handle that in both paths.
- **`_MMU_SAVE_POSITION`/`_MMU_RESTORE_POSITION` are real HH plumbing — keep
  the calls in PAUSE/RESUME**: defined in `mmu/base/mmu_sequence.cfg` and
  called per HH's documented client-macro pattern (save before `PAUSE_BASE`,
  restore before `RESUME_BASE`, guarded on `printer.mmu.enabled`). Idempotent —
  HH's Python wrapper also fires them when enabled, so the duplicate is safe.
- **`mmu/base/` contains absolute symlinks into `/home/pi/addon-packages/Happy-Hare/`**
  (mmu_sequence.cfg, mmu_software.cfg, mmu_state.cfg, etc.). They dangle on a
  local checkout, and `grep -r` skips symlinks (`grep -R` follows them). A 2026-07
  audit wrongly flagged `_MMU_SAVE_POSITION` as undefined because of this. Never
  declare a macro undefined from a repo grep — confirm on the printer with
  `curl -s localhost:7125/printer/gcode/help`.
- **Happy Hare `update_trsync` is a no-op on Kalico**: HH monkey-patches a
  constant that Kalico replaced with `[danger_options] multi_mcu_trsync_timeout`.
  Set trsync timeout in `danger_options`, disable HH's `update_trsync: 0`.
- **Water cooling sensor pin conflict**: `water_cooling_thermistor.cfg` and
  `motor_thermistors.cfg` motor_4 both use `mcu:e_sensor_pin`. Water cooling
  is not in the active include chain — resolve before enabling.
- **Thermal expansion offset clamping**: `_BEACON_SET_NOZZLE_TEMP_OFFSET`
  clamps to `max_thermal_offset` from `_PRINTER_VARS` and logs an error
  instead of halting. A bad coefficient won't crash the nozzle into the bed.
- **MPC deploy requires three things**: (1) `control: mpc` in extruder config,
  (2) MPC parameters (heater_power, cooling_fan, filament_*), and (3) remove
  old PID values from the SAVE_CONFIG block. Missing any one silently keeps
  PID active — `MPC_CALIBRATE` won't even register as a command.
- **Klipper macro boolean coercion**: `variable_foo: True` in a macro is
  returned as the *string* `"True"`, not a Python bool. `"False"` is also
  truthy. Always use `|lower == 'true'` for reliable boolean checks, never
  bare `|default(false)` without the string comparison.

## Style
- **Indentation**: 2-space, no tabs. Upstream snippets (e.g., BeaconPrinterTools) often
  use tabs — convert on paste.
- `vars` = `printer["gcode_macro _PRINTER_VARS"]` (universal alias)
- `svv` = `printer.save_variables.variables` (universal alias)
- `wv` = `printer["gcode_macro _WIPER_VARS"]` (nozzle cleaner alias)
- `printer["gcode_macro CustomVariables"]` — per-print state (filament_type, slicer, skew_profile, nozzle_wiper_state)
- Prefer `_HELPER` or `_VARS` prefix for internal-only macros (e.g., `_PARK_BASE`, `_CENTER_AXIS`, `_WIPER_VARS`)

## Motor Slot Map (BTT Octopus MAX EZ V1.0)
| Slot | Step/Dir/Enable | CS/UART | DIAG Pin | DIAG Jumper | Current Use |
|------|----------------|---------|----------|:-----------:|-------------|
| Motor1 | PC13/PC14/PE6 | PG14 | PF0 | Yes | **DO NOT USE** — PC13 is VBAT-domain |
| Motor2 | PE4/PE5/PE3 | PG13 | PF2 | Yes | stepper_y |
| Motor3 | PE1/PE0/PE2 | PG12 | PF4 | Yes | extruder (on toolboard — free) |
| Motor4 | PB8/PB9/PB7 | PG11 | PF3 | Yes | stepper_x |
| Motor5 | PB5/PB4/PB6 | PG10 | PF1 | Yes | z0 |
| Motor6 | PG15/PB3/PD5 | PG9 | PC15 | Yes | z1 |
| Motor7 | PD3/PD2/PD4 | PD7 | — | No | z2 |
| Motor8 | PA10/PA9/PA15 | PD6 | — | No | Free |
| Motor9 | PA8/PC7/PC9 | PG8 | — | No | stepper_y1 (AWD) |
| Motor10 | PG6/PC6/PC8 | PG7 | — | No | stepper_x1 (AWD) |

- CS/UART column: SPI chip-select for TMC5160 (XY), UART for TMC2209 slots
- DIAG jumpers only on Motor1–Motor6 (required for sensorless homing)
- **Motor1 (PC13)**: VBAT-domain pin on STM32H723 with limited drive strength.
  With dedge mode and 48V TMC5160s, phantom steps cause motor drift at idle.
  Do not assign any stepper here.
- CPAP fan signal on PB14 (BLTouch control header, active `[fan]` section)
- Manual: `manuals/BTT/Max EZ/`

## BTT MMB Pin Notes
- PA2 (`MMU_NEOPIXEL` alias): repurposed as EREC cutter servo signal — **not available for Neopixel**
- RGB port 5V is current-limited (insufficient for servo); servo power is taken from the i2c port 5V header instead
- All other MMB aliases in `mmu/base/mmu.cfg` `[board_pins mmu]`
