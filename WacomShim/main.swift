// SPDX-License-Identifier: GPL-3.0-or-later
// MockTab — native macOS driver for supported drawing tablets
//
// Copyright (C) 2026  This file is part of MockTab.
//
// MockTab is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// MockTab is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with MockTab.  If not, see <https://www.gnu.org/licenses/>.

import AppKit

// WacomShim — headless Apple Events responder for Adobe Photoshop / Illustrator.
//
// Bundle ID: com.wacom.TabletDriver
//
// Adobe queries for a process with this bundle ID before trusting NSEvent
// tablet pressure.  This helper runs as a background-only process alongside
// MockTab and responds to the Apple Events protocol that Wacom's official
// macOS driver exposes.
//
// When Adobe sends an eSendTabletEvent request asking for a pointer or
// proximity replay, this process posts a distributed notification to MockTab
// so the actual HID state can be re-injected.

let app = NSApplication.shared  // must be first; registers process with Launch Services
let delegate = ShimApp()
app.delegate = delegate
app.run()
