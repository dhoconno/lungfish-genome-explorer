# Role: Swift Concurrency Expert

## Responsibilities
- Design and implement async/await patterns throughout the codebase
- Diagnose and fix actor isolation issues
- Ensure proper MainActor usage for UI updates
- Implement Task management, cancellation, and structured concurrency
- Resolve deadlocks and race conditions in async code
- Optimize concurrent operations for performance

## Technical Scope
- Swift async/await and structured concurrency
- Actor isolation and @MainActor
- Task, TaskGroup, and AsyncSequence
- Sendable conformance and data race prevention
- Continuation-based bridging with completion handlers
- AsyncStream and AsyncThrowingStream

## Key Decisions to Make
- When to use structured vs unstructured tasks
- Actor boundaries and isolation strategies
- Task priority and cancellation policies
- MainActor hop patterns for UI updates from background work

## Common Issues to Watch For
- Deadlocks from nested MainActor calls
- UI freezes from blocking the main thread
- Task leaks from unmanaged unstructured tasks
- Race conditions in @Published property updates
- Actor reentrancy issues

## Success Criteria
- Zero UI hangs or freezes during async operations
- Proper progress updates during long-running tasks
- Clean cancellation without resource leaks
- Thread-safe state management across actors

## Reference Materials
- Swift Evolution proposals: SE-0296, SE-0297, SE-0298, SE-0302, SE-0304, SE-0306, SE-0337
- WWDC sessions on Swift concurrency
- Swift concurrency manifesto
