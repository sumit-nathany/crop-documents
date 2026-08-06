import DocumentCropCore
import Foundation

// Mac front end for DocumentCropCore. Everything here is shell — argument parsing, walking
// the filesystem, printing progress. The pixel pipeline is entirely in the core package,
// which the iOS app links unchanged.

let arguments = Array(CommandLine.arguments.dropFirst())

// Diagnostic subcommand: report the quarter turn the orienter detects for each file,
// without modifying anything. Used by lab/ to regression-test auto-rotate against
// known-orientation fixtures. Undocumented in --help; it is a developer tool.
if arguments.first == "probe-orientation" {
    ProbeCommand.run(paths: Array(arguments.dropFirst()))
    exit(0)
}
if arguments.first == "probe-skew" {
    ProbeCommand.runSkew(paths: Array(arguments.dropFirst()))
    exit(0)
}
if arguments.first == "probe-trim" {
    ProbeCommand.runTrim(paths: Array(arguments.dropFirst()))
    exit(0)
}

let options: Options
do {
    guard let parsed = try Options.parse(arguments) else {
        print(Options.usage)
        exit(0)
    }
    options = parsed
} catch {
    FileHandle.standardError.write(Data("❌  \(error.localizedDescription)\n".utf8))
    exit(2)
}

let runner = BatchRunner(options: options)

if options.watch {
    runner.runWatch()
} else {
    let succeeded = runner.runBatch()
    exit(succeeded ? 0 : 1)
}
