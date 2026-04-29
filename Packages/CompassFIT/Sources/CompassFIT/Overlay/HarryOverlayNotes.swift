// HarryOverlayNotes.swift
// CompassFIT
//
// Companion notes for harry_overlay.json

// TODO: Replace placeholder field numbers with real values from HarryOnline's Garmin FIT extensions spreadsheet.
// Spreadsheet reference: https://www.harryonline.net/garmin/fit-file-format/
//
// The overlay JSON currently contains best-guess field numbers for:
// - monitoring_hr (140): Heart rate monitoring samples recorded throughout the day
// - monitoring_info (211): Summary monitoring data including step cycles and active calories
// - sleep_data_info (273): Sleep session summary with score and time range
// - sleep_stage (275): Individual sleep stage entries (awake, light, deep, REM)
// - body_battery (346): Garmin Body Battery energy levels with charge/drain rates
// - training_readiness (369): Training readiness score
// - sleep_restless_moments (382): Restless periods detected during sleep
// - nap (412): Nap sessions with duration and time range
//
// TODO: Validate the stage enum values in sleep_stage (275) against actual Garmin data:
//   0 = deep?, 1 = light?, 2 = REM?, 3 = awake?
//
// TODO: Confirm body_battery (346) field numbers - charged/drained may be delta values or absolute.
//
// TODO: Verify monitoring_hr (140) vs the standard heart rate field in monitoring messages (mesg_num 55).
//       Garmin may use both depending on firmware version.
