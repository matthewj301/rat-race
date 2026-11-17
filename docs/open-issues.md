# Open issues (assignable)

Unlike audits and historical notes, entries here ARE assignments. Fix, then delete the
entry in the same change. Shared-macro issues live in the fleet master's
`~/git/doomcube/docs/open-issues.md`; fix those there first, then port.

## MPC

- **`_PRINT_START_AFTER_PREHEAT` calls `_SET_MPC_MATERIAL` without checking the extruder
  runs MPC** (2026-11-16, review of the FILAMENT_DENSITY change; pre-existing).
  `custom/macros/print.cfg` calls it unconditionally. Doomcube and K3D guard it with
  `printer.configfile.settings.extruder.control == "mpc"`. On a PID extruder the macro now
  fails on the missing `filament_density` (before: at `MPC_SET`). Add the same guard as the
  master, and a consumer-port test for the PID branch.
