// DebugRelocationSmoke.swift - Non-UI entry probe for relocated local builds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

public enum DebugRelocationSmoke {
    public static func outputIfRequested(arguments: [String]) -> String? {
        guard arguments.dropFirst() == ["--debug-relocation-smoke"] else {
            return nil
        }
        return "debug-app-executable-smoke-ok"
    }
}
