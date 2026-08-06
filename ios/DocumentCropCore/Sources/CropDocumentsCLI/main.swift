import DocumentCropCore
import Foundation

// Mac front end for DocumentCropCore. Everything here is shell — argument parsing, walking
// the filesystem, printing progress. The pixel pipeline is entirely in the core package,
// which the iOS app links unchanged.

let arguments = Array(CommandLine.arguments.dropFirst())

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
