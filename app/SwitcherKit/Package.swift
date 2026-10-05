// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Zephydian contributors

// SwitcherKit: the app switcher (⌘Tab) and Finder cut and paste, copied from Vorssaint
// (github.com/vorssaint/vorssaint-utils, GPL-3.0-or-later). It keeps Vorssaint's own Swift
// settings (Swift 5 language mode, no main-actor default), so it lives in its own package.

import PackageDescription

let package = Package(
    name: "SwitcherKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SwitcherKit", targets: ["SwitcherKit"])],
    targets: [.target(name: "SwitcherKit", path: "Sources/SwitcherKit")]
)
