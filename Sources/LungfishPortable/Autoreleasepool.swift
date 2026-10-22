// Autoreleasepool.swift - A pass-through autoreleasepool where the Objective-C runtime is absent
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

#if !canImport(ObjectiveC)
/// Runs `body` and returns its value.
///
/// The Foundation of the Static Linux SDK has no `autoreleasepool`, and a platform without the Objective-C runtime has
/// no autoreleased objects to drain. This pass-through lets the portable code keep its calls unchanged on both
/// platforms. The Mac keeps the Objective-C runtime's `autoreleasepool`.
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif
