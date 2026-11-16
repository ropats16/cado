import AppKit

// Before anything reads or creates the support folder (ConfigStore, the CLI
// paths): move a pre-rename one across, once.
LegacyMigration.runAtLaunch()

// Diagnostic path: transcribe a WAV and exit (no UI, no permissions needed).
if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run(arguments: CommandLine.arguments))
}
// Records a few seconds of system audio to a WAV (process tap, macOS 14.2+).
if CommandLine.arguments.contains("--system-audio-test") {
    exit(SystemAudioSelfTest.run(arguments: CommandLine.arguments))
}
// A whole meeting from two WAVs (Me, Them) through the real engine to a note.
if CommandLine.arguments.contains("--meeting-test") {
    exit(MeetingSelfTest.run(arguments: CommandLine.arguments))
}
// Benchmark: run an engine over the bench fixtures, print a table, write JSON.
if CommandLine.arguments.contains("--bench") {
    exit(BenchCommand.run(arguments: CommandLine.arguments))
}

// Menu-bar-only agent: no Dock icon, no main menu/window by default.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
