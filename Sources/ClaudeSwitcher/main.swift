import Foundation

// `ClaudeSwitcher list|save|switch <name>` runs the CLI; anything else launches the menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, CLI.commands.contains(command) {
    CLI.run(arguments)
} else if let name = arguments.first, !name.hasPrefix("-") {
    CLI.run(["switch"] + arguments)
} else {
    ClaudeSwitcherApp.main()
}
