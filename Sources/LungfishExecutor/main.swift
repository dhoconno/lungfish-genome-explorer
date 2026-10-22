import Foundation

let executorResult = ExecutorCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(executorResult.standardOutput.utf8))
if !executorResult.standardError.isEmpty {
    FileHandle.standardError.write(Data(executorResult.standardError.utf8))
}
exit(executorResult.status)
