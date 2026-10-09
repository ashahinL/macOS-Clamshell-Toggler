//
//  Clamshell — menu bar companion for the `clamshell` CLI.
//
//  A tiny NSStatusItem that shows whether closing the lid will keep this Mac
//  awake, and opens a panel to switch modes without a terminal. All state
//  lives in the CLI; this is only a view onto it.
//
//  SPDX-License-Identifier: MIT
//

import AppKit
import Foundation

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
