# Macro Audit Playbook — 2026-07 (rat-race reference implementation)

Portable fix/optimization set from the 2026-07 VCore 3.1 macro audit. Written so an
agent can apply the same changes to another Kalico printer sharing this macro
family (Annex K3, Doomcube, etc.). Each item has a **Detect** grep and an **Apply**
change. Reference diffs live in this repo's git history (commit tagged
"macro audit 2026-07"); when in doubt, diff the same-named file here.

Prerequisites for the target printer: Kalico (not mainline Klipper), Beacon
contact workflow, `_PRINTER_VARS` pattern, and the shared macro set
(`print.cfg`, `heating_cooling.cfg`, `fans.cfg`, `nozzle_cleaner.cfg`, etc.).
Skip any item whose subsystem the target doesn't have (MMU, chamber heating,
wiper servo). Follow the CLAUDE.md workflow: verify greps before deploy, diff
local↔printer before overwriting anything.

## Architecture note: DynamicMacros is obsolete on Kalico

Kalico ≥ v2026.04 natively handles `gcode: !!include <file>.py` and `!`-prefixed
Python lines (`configfile.py getscript()` → Python template). The native helper
API in `gcode_macro.py` provides `emit`, `wait_moves`, `wait_while`, `wait_until`,
`sleep`, `set_gcode_variable`, `respond_info`, `raise_error`, `blocking`,
`emergency_stop`, `math`, `own_vars`, and a subscriptable `printer` wrapper.
Exceptions raise real gcode errors (they propagate and abort the caller).

- **Detect:** `[dynamicmacros]` section anywhere; `dynamicmacros.py` in
  `~/klipper/klippy/extras/` on the host.
- **Apply:** delete the plugin file from the host (it never loads without the
  config section); validate Python macros against the Kalico API above, not the
  plugin's. No changes needed to the macro files themselves.

## P0 bug patterns

1. **Undefined macro calls in PAUSE/RESUME (Happy Hare printers only).**
   - Detect: `grep -rn "_MMU_SAVE_POSITION\|_MMU_RESTORE_POSITION" custom/ mmu/`
   - Apply: delete both call blocks. HH manages position save/restore internally;
     these names exist nowhere. Any hit is a live "Unknown command" bug because
     HH's `user_pause_extension: 'PAUSE'` routes every MMU pause through our macro.

2. **`G4 S` is a silent no-op.**
   - Detect: `grep -rn "G4 S" --include="*.cfg" .`
   - Apply: `G4 P{(<seconds>) * 1000}`.

3. **`ALL_FANS_OFF` right after scheduling `FILTER_DELAYED_STOP`.**
   - Detect: in COOLDOWN_SEQUENCE (any branch), `ALL_FANS_OFF` appearing after
     `UPDATE_DELAYED_GCODE ID=FILTER_DELAYED_STOP`.
   - Apply: replace with `TURN_PART_COOLING_FAN_OFF` + `CHAMBER_HEATING_FANS_OFF`
     (the latter turns bed/chamber fans off but keeps the filter running — verify
     the target's fans.cfg has the same helper semantics first). The filter must
     stay on until the delayed stop fires.

4. **`HOTEND_TEMP|default(0)` → cold print start.**
   - Detect: PRINT_START consuming `params.HOTEND_TEMP|default(0)` with no floor check.
   - Apply: right after the set, abort loudly:
     `{% if hotend_temp < 150 %}{ action_raise_error("PRINT_START: HOTEND_TEMP missing or below 150C (got %.0f). Pass HOTEND_TEMP from the slicer." % hotend_temp) }{% endif %}`

5. **CLEAN_NOZZLE side effects not gated on SKIP_HEATING.**
   - Detect: any block in CLEAN_NOZZLE gated only on `is_printing` while others
     gate on `skip_heating == 0 and not is_printing` (in rat-race it was the
     post-clean Z move).
   - Apply: compute one `{% set standalone = (skip_heating == 0 and not is_printing) %}`
     at the top and gate every heat/cool/Z-move block on it. A PRINT_START-invoked
     clean must not move Z or touch temps between Beacon cal steps.

## P1 robustness patterns

6. **COOLDOWN_SEQUENCE QUICK semantics.** QUICK=1 must mean *fast* everywhere
   (matching PREHEAT). Flip the branch condition and default (`|default(0)` so a
   bare call on warp-prone material still gets the safe stepped cooldown), update
   PRINT_END to pass `QUICK=0` for complete / `QUICK=1` for cancel, and validate
   REASON against `["complete", "cancel"]` with `action_raise_error` on anything else.
   **Keep `M104 S0` immediately after the opening RESPOND** — the controlled
   branch only reaches TURN_OFF_HEATERS after the (long) stepped bed cooldown,
   and without the early hotend-off the nozzle sits at print temp the whole time.
   (This regression was introduced and caught during the rat-race pass — don't repeat it.)

7. **Divide-by-zero in BEACON_APPLY_MULTIPLIER.** Guard `temp_delta == 0` and
   `coefficient_per_degree == 0` with RESPOND TYPE=error branches before the math.

8. **SAVE/RESTORE_GCODE_STATE around Beacon nozzle-offset calibration macros.**
   Wrap `BEACON_CALIBRATE_NOZZLE_TEMP_OFFSET` and `_BEACON_PROBE_NOZZLE_TEMP_OFFSET`.
   Safe only because `_BEACON_NOZZLE_TEMP_OFFSET` (called before the restore) only
   prints — **verify on the target that nothing between SAVE and RESTORE applies a
   SET_GCODE_OFFSET**, since RESTORE_GCODE_STATE reverts gcode offsets too.

9. **Out-of-order coefficient store.** In `_BEACON_STORE_NOZZLE_TEMP_OFFSET`'s
   high-temp branch, error-and-skip the SAVE_VARIABLE when `reference_z == 0`
   (no prior 150C pass).

10. **chamber_heating.py hardening** (chamber-heated printers): init `cycle = -1`
    before the loop; break on `printer["print_stats"]["state"] in ("cancelled", "error")`
    (not "paused"/"standby" — the loop legitimately runs during PRINT_START);
    call `TA_CHAMBER_STOP` (configfile-defined-guarded) from PAUSE and CANCEL_PRINT.
    **Known limitation (verified empirically on rat-race):** the mixing loop is ONE
    gcode command, so it holds the gcode mutex for its whole duration — console
    `TA_CHAMBER_STOP`, `PAUSE`, and `CANCEL_PRINT` all queue behind it and cannot
    interrupt it mid-run. This is identical to `M190` semantics and predates the
    audit; the wired stop/cancel checks only cover flags set before the loop
    starts. The real mid-run abort is emergency stop (M112 / Moonraker
    emergency_stop), then FIRMWARE_RESTART — safe, since the loop can run with
    `BED_TEMP=0 HOTEND_TEMP=0`. A true fix would restructure the loop as a
    self-rescheduling delayed_gcode (mutex freed between cycles) at the cost of
    PREHEAT losing its blocking semantics — deliberately not done in this pass.

11. **Servo `initial_angle` must equal the stowed angle** (wiper printers) —
    otherwise every boot twitches the servo.

## P2 performance patterns (measured on rat-race; validate per printer)

12. **Fire heaters before homing.** First lines of PRINT_START (after param
    validation): non-blocking `M140 S{bed_temp}` + `M104 S{contact_cal_temp}`.
    Bed heating then overlaps MAYBE_HOME + SYNC_MOTORS (~1–2 min per cold start).
    PREHEAT's own M140/M104 re-issues are idempotent — leave PREHEAT alone.

13. **Conditional motor sync** (motors_sync printers):
    ```
    {% if not (printer.motors_sync is defined and printer.motors_sync.applied and 'xyz' in printer.toolhead.homed_axes) %}
      SYNC_MOTORS ACCEL_CHIP=<chip>
    {% else %}
      RESPOND MSG="Motor sync still valid - skipping"
    {% endif %}
    ```
    Safe because motor-off clears homed_axes, so "still homed" ⇒ phases held.
    Pair with: PRINT_END disables motors only on `reason == "cancel"`; the
    idle_timeout gcode releases them otherwise. Drop any RETRIES= override —
    the `[motors_sync]` config owns retry policy. Also run `SYNC_MOTORS_CALIBRATE`
    once per printer (builds the steps model; makes every sync faster).

14. **Skip redundant soak after chamber heat.** In PREHEAT, when
    `use_dynamic_heating` ran and the chamber sensor is at target, set the soak
    to zero — the mixing loop already held everything at temp:
    ```
    {% set chamber_at_target = (sensor_key in printer) and chamber_temp > 0 and (printer[sensor_key].temperature|float >= chamber_temp - vars.chamber_start_delta|float) %}
    {% if quick == 0 and soak_minutes > 0 and not (use_dynamic_heating and chamber_at_target) %}
    ```

15. **`chamber_start_delta` tunable** (`_PRINTER_VARS`, default 0): lets the
    chamber loop exit at `target - delta`; thermal momentum covers the rest during
    cal/clean/purge. Read in chamber_heating.py via
    `float(params.get("START_DELTA", vars["chamber_start_delta"]))`. Start at 0,
    raise to 2–3 after validating a print.

16. **Rename mm/min locals.** Jinja locals holding `* 60` values must be
    `*_feedrate`, not `*_speed` (park/homing macros). Cosmetic but prevents 60x
    unit bugs in future edits.

## Verification (run all before deploy, per printer)

1. Greps must be clean: `_MMU_SAVE_POSITION|_MMU_RESTORE_POSITION`, `G4 S`
   (in .cfg), `reason_code`, `RETRIES=8`; `ALL_FANS_OFF` has no callers inside
   COOLDOWN_SEQUENCE; exactly one COOLDOWN_SEQUENCE caller passing the new QUICK
   semantics.
2. `python3 -c "import ast; ast.parse(open('custom/macros/python/chamber_heating.py').read())"`
3. Cross-reference every new `vars.*` access against `_PRINTER_VARS` declarations
   (`chamber_start_delta` is the new one).
4. Diff local↔printer for every file you're about to overwrite (printer copies
   must match git HEAD — abort on drift, reconcile first).
5. Deploy, FIRMWARE_RESTART, confirm clean startup in the **current** klippy.log
   session (`Start printer at` boundary).
6. Smoke tests from a cold idle printer: `COOLDOWN_SEQUENCE QUICK=1` then
   `QUICK=0` (filter must keep running until FILTER_DELAYED_STOP fires);
   `TA_CHAMBER_HEAT TARGET_CHAMBER_TEMP=<below ambient> BED_TEMP=0 HOTEND_TEMP=0`
   (must complete immediately, no heating); PAUSE → RESUME with MMU enabled and
   the printer already homed (no Unknown command; an unhomed printer may fail in
   HH's wrapper on Beacon contact homing with a cold nozzle — environmental, not
   a macro bug). Do NOT test mid-run TA_CHAMBER_STOP — it cannot be delivered
   while the loop runs (see item 10); it would require an emergency stop to recover.
7. First print: time PRINT_START against a pre-change klippy.log baseline;
   verify first layer unchanged. Second back-to-back print: homing+sync skipped,
   first layer still good.
