import Foundation

// The first statement blocks SIGTERM, SIGINT and SIGHUP on Linux, before any thread exists, so every later thread
// inherits the mask and the step's dispatch signal sources see them (ExecutorSignals). Modes that run no tool unblock.
ExecutorSignals.blockAtStart()

let executorArguments = Array(CommandLine.arguments.dropFirst())
if executorArguments.first == "step" {
    exit(StepCommand.main(Array(executorArguments.dropFirst())))
}
if executorArguments.first == "run" {
    exit(RunCommand.main(Array(executorArguments.dropFirst())))
}
if executorArguments.first == "read-fastq" {
    exit(ReadCommand.main(Array(executorArguments.dropFirst())))
}
ExecutorSignals.unblock()
if let mode = executorArguments.first, ProcessProbes.modes.contains(mode) {
    exit(ProcessProbes.main(executorArguments))
}

let executorResult = ExecutorCommand.run(arguments: executorArguments)
FileHandle.standardOutput.write(Data(executorResult.standardOutput.utf8))
if !executorResult.standardError.isEmpty {
    FileHandle.standardError.write(Data(executorResult.standardError.utf8))
}
exit(executorResult.status)
