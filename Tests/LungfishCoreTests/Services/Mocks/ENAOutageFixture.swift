// ENAOutageFixture.swift - The error page ENA's portal API served during its 2026-10-04 outage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// On 2026-10-04 ENA's portal API answered every request with HTTP 500 and
/// an HTML page, while NCBI's E-utilities worked. Tests replay the outage
/// through mock HTTP clients with this page, shortened.
enum ENAOutageFixture {
    static let page = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>500 Internal Server Error</title></head>
    <body>
    <h1>Internal Server Error</h1>
    <p>The server encountered an internal error and was unable to complete your request.</p>
    </body>
    </html>
    """
}
