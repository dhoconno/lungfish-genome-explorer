// TextBadgeIconTests.swift — Tests for TextBadgeIcon rendering
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import LungfishApp

struct TextBadgeIconTests {

    @Test
    func rendersBadgeWithCorrectSize() {
        let image = TextBadgeIcon.image(text: "NVD", size: NSSize(width: 16, height: 16))
        #expect(image.size.width == 16)
        #expect(image.size.height == 16)
    }

    @Test
    func rendersBadgeForNao() {
        let image = TextBadgeIcon.image(text: "NM", size: NSSize(width: 16, height: 16))
        #expect(image.size.width == 16)
        #expect(image.size.height == 16)
    }

    @Test
    func reusesDefaultBadgeImageForIdenticalRequests() {
        let size = NSSize(width: 16, height: 16)
        let first = TextBadgeIcon.image(text: "NVD", size: size)
        let second = TextBadgeIcon.image(text: "NVD", size: size)

        #expect(first === second)
    }

    @Test
    func rendersBadgeAtDifferentSizes() {
        for dimension in [12, 16, 20, 24] {
            let size = NSSize(width: dimension, height: dimension)
            let image = TextBadgeIcon.image(text: "NVD", size: size)
            #expect(image.size.width == CGFloat(dimension))
            #expect(image.size.height == CGFloat(dimension))
        }
    }

    @Test
    func rendersWithCustomColor() {
        let image = TextBadgeIcon.image(
            text: "NVD",
            size: NSSize(width: 16, height: 16),
            fillColor: .systemBlue
        )
        #expect(image.size.width == 16)
    }
}
