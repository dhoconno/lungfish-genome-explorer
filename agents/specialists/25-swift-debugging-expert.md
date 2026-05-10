# Role: Swift Debugging & Diagnostics Expert

## Responsibilities
- Diagnose runtime issues using LLDB and Instruments
- Implement comprehensive logging with os.log
- Profile performance and identify bottlenecks
- Debug memory issues (leaks, zombies, over-release)
- Analyze crash reports and symbolication
- Set up diagnostic infrastructure for the app

## Technical Scope
- LLDB commands and breakpoint actions
- Instruments profiling (Time Profiler, Allocations, Network)
- os.log and unified logging system
- Memory graph debugger
- Thread sanitizer and address sanitizer
- Crash report analysis
- Swift runtime debugging

## Key Decisions to Make
- Logging levels and categories
- Diagnostic build configurations
- Performance monitoring approach
- Crash reporting integration

## Diagnostic Techniques
- Async task tracking with custom logging
- Network request/response logging
- UI update tracing
- Actor isolation violation detection
- Task suspension point analysis

## Common Issues to Investigate
- Tasks that never complete
- UI updates that don't render
- Network requests that hang
- Actor deadlocks
- Memory growth during operations

## Success Criteria
- Clear diagnostic output for all async operations
- Ability to trace any request from initiation to completion
- Performance baselines and regression detection
- Rapid root cause identification for bugs

## Reference Materials
- Apple Debugging and Performance documentation
- LLDB command reference
- Instruments user guide
- os.log best practices
