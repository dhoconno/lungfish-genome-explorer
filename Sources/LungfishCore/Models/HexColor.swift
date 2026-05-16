// HexColor.swift - Foundation-only RGB color value
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Foundation-only color value used by Core models.
public struct HexColor: Sendable, Codable, Equatable, Hashable {
    public enum ParseError: Error, Equatable {
        case invalidHexString(String)
    }

    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    public init(hex: String) throws {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value = String(value.dropFirst())
        }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }

        guard value.count == 6, let integer = UInt32(value, radix: 16) else {
            throw ParseError.invalidHexString(hex)
        }

        self.init(
            red: Double((integer >> 16) & 0xFF) / 255.0,
            green: Double((integer >> 8) & 0xFF) / 255.0,
            blue: Double(integer & 0xFF) / 255.0
        )
    }

    public var hexString: String {
        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    public static let fallbackGray = HexColor(red: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0)

    private static func clamp(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
