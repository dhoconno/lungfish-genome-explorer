import Foundation

let htcResult = HTCCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(htcResult.standardOutput.utf8))
if !htcResult.standardError.isEmpty {
    FileHandle.standardError.write(Data(htcResult.standardError.utf8))
}
exit(htcResult.status)
