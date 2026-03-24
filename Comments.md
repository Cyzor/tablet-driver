2026-03-23

Google Gemini's Assessment:

Here is an analysis of the "askew" architectural assumptions and organization:

### 1. Hardcoded Device Instantiation (`TabletManager.swift`)
The most significant scalability bottleneck is in `TabletManager.deviceConnected(_:)`. There is no dynamic discovery or factory pattern for drivers. Instead, it uses a manual `switch` statement on the `productID` to instantiate specific classes (`PTH851Device`, `PTH660Device`, etc.).
- **Impact:** Adding a new device requires modifying the core `TabletManager` class.
- **Fix:** A registry or factory pattern where device drivers register themselves with their supported `productID`s would decouple this.

### 2. Single-Instance Limitation (`DeviceContext.swift`)
The `contexts` dictionary in `TabletManager` is keyed by `productID` (an `Int`).
- **Impact:** You cannot connect two identical tablets (e.g., two Intuos Pro M units) simultaneously. The second device will overwrite the context of the first, potentially causing driver state (smoothing, click handling) to bleed between them or leaving the first device in a zombie state.
- **Fix:** Contexts should be keyed by a unique instance identifier (like the `IOHIDDevice` pointer or a UUID), not the model ID.

### 3. Duplicated Device Specifications (`TabletAreaView.swift`)
The UI has no access to the driver's actual capabilities. `TabletAreaView` contains a hardcoded `TabletModel` enum that manually duplicates the resolution (`maxX`, `maxY`) and aspect ratio for every supported device.
- **Impact:** If you update a driver's spec (e.g. `PTH860Device.swift`), you must remember to manually update `TabletAreaView.swift` or the UI mapping will be incorrect.
- **Fix:** The `TabletDevice` protocol should expose a metadata structure that the UI can consume dynamically.

### 4. Scattered Device Knowledge (`DeviceRegistry.swift`)
Knowledge about which pens belong to which tablets is hardcoded in `DeviceRegistry.penName(forProductID:)`.
- **Impact:** Yet another file to modify when adding a new device.
- **Fix:** This information should ideally live within the `TabletDevice` implementation or a centralized device definition file.

### 5. Run Loop Management
The codebase correctly identifies a critical macOS specific requirement: using `kCFRunLoopCommonModes` for HID callbacks.
- **Note:** This is "askew" compared to standard POSIX/Linux drivers but is practically mandatory for a functional macOS mouse-replacement driver to avoid freezing during drag operations (which enter `NSEventTrackingRunLoopMode`).

### 6. "One-Way" Dependency
The `App` (UI) and `Driver` layers are co-located in the same module. The UI directly imports and relies on specific driver classes and the singleton `TabletManager`.
- **Fix:** Separating the driver logic into a local Swift Package would enforce better boundaries and prevent the UI from reaching into driver internals.

### Summary
The project is functional but brittle. Adding a new device currently requires "shotgun surgery"—modifying `TabletManager` (instantiation), `TabletAreaView` (UI specs), and `DeviceRegistry` (pen naming) simultaneously. Refactoring to a data-driven device definition system would resolve most of these issues.

