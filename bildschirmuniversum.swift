#!/usr/bin/env swift
// bildschirmuniversum — align and position built-in + external monitors and set refresh rate to 60 Hz

import CoreGraphics
import Foundation

// Constants
struct Constants {
  static let marketingVersion = "0.2.0"
}

// MARK: - Helpers

func printError(_ msg: String) { fputs("error: \(msg)\n", stderr) }
func printWarn(_ msg: String)  { fputs("warning: \(msg)\n", stderr) }

// MARK: - Private CoreGraphics rotation API (dynamically resolved)
//
// The rotation API is private and has changed across macOS versions:
//
//   macOS 10.15 – 15:  CGSSetDisplayRotation(connection, displayID, degrees: Double) -> Int32
//                      (requires a CGS connection obtained via CGSMainConnectionID)
//   macOS 26+:         SLSSetDisplayRotation(displayID, degrees: Int32) -> Int32
//                      (no connection argument; degrees are an integer)
//
// We resolve both at runtime with dlopen/dlsym and expose a single unified
// closure so the rest of the script need not care about the difference.

import Darwin

private typealias CGSMainConnectionIDFn   = @convention(c) () -> Int32
private typealias CGSSetDisplayRotationFn = @convention(c) (Int32, CGDirectDisplayID, Double) -> Int32
private typealias SLSSetDisplayRotationFn = @convention(c) (CGDirectDisplayID, Int32) -> Int32

/// Handle to the library that exports the private CGS/SLS rotation symbols.
private let _cgsHandle: UnsafeMutableRawPointer? = {
    // SkyLight is the home of the private CGS/SLS layer since macOS 10.15.
    // Fall back to a plain RTLD_DEFAULT search so it also works on older systems
    // or if the path ever changes.
    let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    return dlopen(skyLight, RTLD_LAZY | RTLD_LOCAL)
        ?? dlopen(nil, RTLD_LAZY | RTLD_LOCAL)
}()

private func cgsSymbol<T>(_ name: String) -> T? {
    guard let handle = _cgsHandle, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

/// Unified display-rotation setter: returns nil when neither API is available.
/// Signature: (displayID, degrees) -> errorCode (0 = success)
private let _setDisplayRotation: ((CGDirectDisplayID, Double) -> Int32)? = {
    // macOS 26+: SLSSetDisplayRotation(displayID, Int32) -> Int32
    if let fn: SLSSetDisplayRotationFn = cgsSymbol("SLSSetDisplayRotation") {
        return { displayID, degrees in fn(displayID, Int32(degrees)) }
    }
    // macOS 10.15–25: CGSSetDisplayRotation(connection, displayID, Double) -> Int32
    let connFn: CGSMainConnectionIDFn?   = cgsSymbol("CGSMainConnectionID")
    let rotFn:  CGSSetDisplayRotationFn? = cgsSymbol("CGSSetDisplayRotation")
    if let connFn, let rotFn {
        return { displayID, degrees in rotFn(connFn(), displayID, degrees) }
    }
    return nil
}()

// MARK: - Rotation

/// Rotation angle for an external display.
///
/// - `normal`     — 0°   (landscape, upright)
/// - `left`       — 90°  (portrait, top of panel rotated counter-clockwise)
/// - `upsideDown` — 180° (landscape, inverted)
/// - `right`      — 270° (portrait, top of panel rotated clockwise)
enum Rotation: String {
    case normal, left, upsideDown, right

    /// Case-insensitive initialiser so users can type any capitalisation.
    /// Accepts both `upsideDown` and `upsidedown`.
    init?(_ string: String) {
        switch string.lowercased() {
        case "normal":     self = .normal
        case "left":       self = .left
        case "upsidedown": self = .upsideDown
        case "right":      self = .right
        default:           return nil
        }
    }

    var degrees: Double {
        switch self {
        case .normal:     return 0
        case .left:       return 90
        case .upsideDown: return 180
        case .right:      return 270
        }
    }
}

// MARK: - Display model

struct DisplayInfo {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let refreshRate: Double     // Hz reported by the active mode (0 = unknown)
    let rotation: Double        // current rotation in degrees (0, 90, 180, or 270)

    var x:      Int32 { Int32(bounds.origin.x) }
    var y:      Int32 { Int32(bounds.origin.y) }
    var width:  Int32 { Int32(bounds.width)    }
    var height: Int32 { Int32(bounds.height)   }

    var rateLabel: String {
        refreshRate > 0 ? String(format: " @ %.0f Hz", refreshRate) : ""
    }

    var rotationLabel: String {
        rotation != 0 ? String(format: " rotation=%.0f°", rotation) : ""
    }

    var label: String {
        "id=\(id)  origin=(\(x), \(y))  "
        + "size=\(Int(bounds.width))×\(Int(bounds.height))\(rateLabel)\(rotationLabel)"
    }
}

// MARK: - Alignment

enum Alignment: String {
    case top, center, bottom

    /// Y origin for a display of `height` within a space of `maxHeight`,
    /// anchored at `baseY` (the topmost edge of the display group).
    func yOrigin(displayHeight: Int, maxHeight: Int, baseY: Int) -> Int32 {
        let offset: Int
        switch self {
        case .top:    offset = 0
        case .center: offset = (maxHeight - displayHeight) / 2
        case .bottom: offset = maxHeight - displayHeight
        }
        return Int32(baseY + offset)
    }
}

// MARK: - Built-in display position

enum BuiltinPosition: String {
    case bottom, left, right

    /// New origin for the built-in display relative to the final external group.
    ///
    /// - `bottom`  → centered horizontally below the external group
    /// - `left`    → flush-left of the external group, bottom-aligned
    /// - `right`   → flush-right of the external group, bottom-aligned
    func origin(builtin: DisplayInfo,
                externalLeft: Int32, externalBottom: Int32,
                externalTotalWidth: Int32) -> (x: Int32, y: Int32) {
        switch self {
        case .bottom:
            let x = externalLeft + (externalTotalWidth - builtin.width) / 2
            return (x, externalBottom)
        case .left:
            return (externalLeft - builtin.width, externalBottom - builtin.height)
        case .right:
            return (externalLeft + externalTotalWidth, externalBottom - builtin.height)
        }
    }
}

// MARK: - Refresh rate

let targetHz = 60.0

enum RefreshOutcome {
    case alreadyAtTarget                // no mode change needed
    case found(CGDisplayMode)           // switch to this mode
    case notAvailable(current: Double)  // no 60 Hz mode at this resolution
    case unknownRate                    // display reports 0 Hz (skip silently)
}

/// Finds the best 60 Hz `CGDisplayMode` for `displayID` that matches the
/// current logical + pixel resolution and is usable as a desktop mode.
func findRefreshMode(for displayID: CGDirectDisplayID) -> RefreshOutcome {
    guard let current = CGDisplayCopyDisplayMode(displayID) else { return .unknownRate }
    let currentRate = current.refreshRate
    guard currentRate > 0 else { return .unknownRate }
    guard abs(currentRate - targetHz) > 0.5 else { return .alreadyAtTarget }

    // Match logical size AND pixel size so HiDPI scaling is preserved.
    let lw = current.width;       let lh = current.height
    let pw = current.pixelWidth;  let ph = current.pixelHeight

    let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let cf = CGDisplayCopyAllDisplayModes(displayID, opts),
          let modes = cf as? [CGDisplayMode] else { return .unknownRate }

    let candidate = modes.first { m in
        m.width       == lw && m.height      == lh &&
        m.pixelWidth  == pw && m.pixelHeight == ph &&
        abs(m.refreshRate - targetHz) < 0.5 &&
        m.isUsableForDesktopGUI()
    }

    if let mode = candidate { return .found(mode) }
    return .notAvailable(current: currentRate)
}

// MARK: - Argument parsing

let args = CommandLine.arguments
var dryRun      = false
var noAlign     = false
var noRefresh   = false
var noUnmirror  = false
var alignment   = Alignment.bottom
var builtinPos: BuiltinPosition? = nil
var rotateLeft:  Rotation? = nil   // desired rotation for the display ending in the left slot
var rotateRight: Rotation? = nil   // desired rotation for the display ending in the right slot
var i = 1
while i < args.count {
    switch args[i] {
    case "-h", "--help":
        print("""
        bildschirmuniversum — align and position built-in + external monitors and set refresh rate to 60 Hz

        Usage:
          bildschirmuniversum [options]

        Options:
          --align top|center|bottom      Vertical alignment when swapping (default: bottom).
          --no-align                     Skip vertical alignment when swapping.
          --builtin bottom|left|right    Reposition the built-in display relative to the
                                         external group:
                                           bottom  — centered below both external displays
                                           left    — to the left, bottom-aligned
                                           right   — to the right, bottom-aligned
          --rotate-left  normal|left|upsideDown|right
                                         Rotation for the display that ends up in the left
                                         slot: normal (0°), left (90° CCW), upsideDown (180°),
                                         right (270° CW).
          --rotate-right normal|left|upsideDown|right
                                         Rotation for the display that ends up in the right
                                         slot (same values as --rotate-left).
          --no-refresh                   Skip the automatic 60 Hz refresh-rate change.
          --no-unmirror                  Skip automatic mirroring detection and removal.
          --dry-run                      Preview changes without applying them.
          -h, --help                     Show this help.
        """)
        exit(0)

    case "-V", "--version":
        print("bildschirmuniversum version \(Constants.marketingVersion)")
        exit(0)

    case "--dry-run":      dryRun     = true
    case "--no-align":     noAlign    = true
    case "--no-refresh":   noRefresh   = true
    case "--no-unmirror":  noUnmirror  = true

    case "--builtin":
        i += 1
        guard i < args.count, let p = BuiltinPosition(rawValue: args[i].lowercased()) else {
            printError("--builtin requires: bottom, left, or right")
            exit(1)
        }
        builtinPos = p

    case "--align":
        i += 1
        guard i < args.count, let a = Alignment(rawValue: args[i].lowercased()) else {
            printError("--align requires: top, center, or bottom")
            exit(1)
        }
        alignment = a

    case "--rotate-left":
        i += 1
        guard i < args.count, let r = Rotation(args[i]) else {
            printError("--rotate-left requires: normal, left, upsideDown, or right")
            exit(1)
        }
        rotateLeft = r

    case "--rotate-right":
        i += 1
        guard i < args.count, let r = Rotation(args[i]) else {
            printError("--rotate-right requires: normal, left, upsideDown, or right")
            exit(1)
        }
        rotateRight = r

    default:
        printError("Unknown argument: \(args[i]). Run with --help for usage.")
        exit(1)
    }
    i += 1
}

if builtinPos != nil && noAlign {
    printError("--builtin cannot be combined with --no-align.")
    exit(1)
}

// MARK: - Discover displays

var totalCount: UInt32 = 0
CGGetActiveDisplayList(0, nil, &totalCount)
var allIDs = [CGDirectDisplayID](repeating: 0, count: Int(totalCount))
CGGetActiveDisplayList(totalCount, &allIDs, &totalCount)

func makeDisplayInfo(_ id: CGDirectDisplayID) -> DisplayInfo {
    let mode = CGDisplayCopyDisplayMode(id)
    let hz   = mode.map { $0.refreshRate } ?? 0
    let rot  = CGDisplayRotation(id)
    return DisplayInfo(id: id, bounds: CGDisplayBounds(id), refreshRate: hz, rotation: rot)
}

var externals: [DisplayInfo] = allIDs
    .filter { CGDisplayIsBuiltin($0) == 0 }
    .map(makeDisplayInfo)
    .sorted { $0.bounds.origin.x < $1.bounds.origin.x }   // left → right

var builtinDisplay: DisplayInfo? = allIDs
    .filter { CGDisplayIsBuiltin($0) != 0 }
    .map(makeDisplayInfo)
    .first

/// Returns the highest-resolution desktop-usable mode for `displayID`.
/// Prefers the mode with the most pixels; among ties, picks the highest refresh rate.
/// This is used to restore the native resolution after programmatic unmirroring,
/// because macOS otherwise resets newly-independent displays to a low fallback (e.g. 800×600).
func bestAvailableMode(for displayID: CGDirectDisplayID) -> CGDisplayMode? {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let cf = CGDisplayCopyAllDisplayModes(displayID, opts),
          let modes = cf as? [CGDisplayMode] else { return nil }
    return modes
        .filter { $0.isUsableForDesktopGUI() }
        .max {
            let pixA = $0.pixelWidth * $0.pixelHeight
            let pixB = $1.pixelWidth * $1.pixelHeight
            if pixA != pixB { return pixA < pixB }
            return $0.refreshRate < $1.refreshRate
        }
}

// MARK: - Disable mirroring if needed

/// Returns IDs of online displays that are non-master members of a mirror set.
func mirroredDisplayIDs() -> [CGDirectDisplayID] {
    var onlineCount: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &onlineCount)
    var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
    CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount)
    return onlineIDs.filter { id in
        CGDisplayIsInMirrorSet(id) != 0 &&
        CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
    }
}

if !noUnmirror && externals.count < 2 {
    let mirrored = mirroredDisplayIDs()
    if !mirrored.isEmpty {
        print("Mirroring detected — \(mirrored.count) display(s) are mirrored.")
        if dryRun {
            print("(dry-run — would disable mirroring for display ID(s): \(mirrored.map(String.init).joined(separator: ", ")))")
        } else {
            var mirrorCfg: CGDisplayConfigRef?
            let merr = CGBeginDisplayConfiguration(&mirrorCfg)
            if merr == .success, let mcfg = mirrorCfg {
                for id in mirrored {
                    CGConfigureDisplayMirrorOfDisplay(mcfg, id, kCGNullDirectDisplay)
                    // Restore native resolution in the same transaction;
                    // otherwise macOS resets the display to a low fallback mode (e.g. 800×600).
                    if let best = bestAvailableMode(for: id) {
                        CGConfigureDisplayWithDisplayMode(mcfg, id, best, nil)
                    }
                }
                if CGCompleteDisplayConfiguration(mcfg, .forSession) == .success {
                    print("✓ Mirroring disabled.")
                    Thread.sleep(forTimeInterval: 1.5)   // let the system settle
                    // Re-discover active displays after unmirroring.
                    var totalCount2: UInt32 = 0
                    CGGetActiveDisplayList(0, nil, &totalCount2)
                    var allIDs2 = [CGDirectDisplayID](repeating: 0, count: Int(totalCount2))
                    CGGetActiveDisplayList(totalCount2, &allIDs2, &totalCount2)
                    externals = allIDs2
                        .filter { CGDisplayIsBuiltin($0) == 0 }
                        .map(makeDisplayInfo)
                        .sorted { $0.bounds.origin.x < $1.bounds.origin.x }
                    builtinDisplay = allIDs2
                        .filter { CGDisplayIsBuiltin($0) != 0 }
                        .map(makeDisplayInfo)
                        .first
                } else {
                    printWarn("Could not disable mirroring — proceeding with current display state.")
                    CGCancelDisplayConfiguration(mirrorCfg!)
                }
            } else {
                printWarn("CGBeginDisplayConfiguration failed while disabling mirroring (code \(merr.rawValue)) — skipping.")
            }
        }
        print()
    }
}

guard externals.count == 2 else {
    printError("Expected exactly 2 external displays, found \(externals.count).")
    switch externals.count {
    case 0:  printError("No external monitors detected — are they connected?")
    case 1:  printError("Only one external monitor detected — connect a second one.")
    default: printError("More than 2 external monitors found — not supported.")
    }
    exit(1)
}

let left  = externals[0]
let right = externals[1]

print("Current arrangement:")
print("  Left : \(left.label)")
print("  Right: \(right.label)")
if let b = builtinDisplay {
    print("  Built-in: \(b.label)")
} else if builtinPos != nil {
    printWarn("--builtin specified but no active built-in display found (lid closed?).")
}
print()

// MARK: - Refresh-rate analysis

// Analyse both displays up front so dry-run can report what would happen.
let leftRefresh  = noRefresh ? RefreshOutcome.alreadyAtTarget : findRefreshMode(for: left.id)
let rightRefresh = noRefresh ? RefreshOutcome.alreadyAtTarget : findRefreshMode(for: right.id)

func refreshSummary(_ outcome: RefreshOutcome, displayID: CGDirectDisplayID) -> String {
    switch outcome {
    case .alreadyAtTarget:            return "already at \(Int(targetHz)) Hz"
    case .found:                      return "→ \(Int(targetHz)) Hz"
    case .notAvailable(let r):        return "60 Hz unavailable (stays at \(Int(r)) Hz)"
    case .unknownRate:                return "refresh rate unknown (skipped)"
    }
}

if !noRefresh {
    print("Refresh rate:")
    print("  Left : \(refreshSummary(leftRefresh,  displayID: left.id))")
    print("  Right: \(refreshSummary(rightRefresh, displayID: right.id))")
    print()
}

// MARK: - Compute new origins

let baseX = left.x
let baseY = min(left.y, right.y)

let maxH               = max(Int(left.height), Int(right.height))
let externalTotalWidth = left.width + right.width
let externalBottom: Int32 = baseY + Int32(maxH)

// ── Swap + align ────────────────────────────────────────────────────────────
// After swap: right.id → left slot, left.id → right slot.
let swapLeftX:  Int32 = baseX
let swapRightX: Int32 = baseX + right.width

let swapLeftY:  Int32 = noAlign ? right.y
    : alignment.yOrigin(displayHeight: Int(right.height), maxHeight: maxH, baseY: Int(baseY))
let swapRightY: Int32 = noAlign ? left.y
    : alignment.yOrigin(displayHeight: Int(left.height),  maxHeight: maxH, baseY: Int(baseY))

// ── Built-in ────────────────────────────────────────────────────────────────
// The built-in position is relative to the final external group, so it's the
// same whether we swap or only align (total width and bottom edge are unchanged).
let builtinOrigin: (x: Int32, y: Int32)? = builtinPos.flatMap { pos in
    guard let b = builtinDisplay else { return nil }
    return pos.origin(builtin: b, externalLeft: baseX,
                      externalBottom: externalBottom,
                      externalTotalWidth: externalTotalWidth)
}

// ── Swap flag ────────────────────────────────────────────────────────────────
// The swap is skipped when --builtin is given (external displays stay put) or
// when any --rotate-* flag is used (rotation-only mode, no positional change).
let doSwap = builtinPos == nil && rotateLeft == nil && rotateRight == nil

// ── Dry run ─────────────────────────────────────────────────────────────────
// After a swap: right.id ends up in the left slot, left.id in the right slot.
// Without a swap: displays stay in place.
let finalLeftID  = doSwap ? right.id : left.id
let finalRightID = doSwap ? left.id  : right.id

if dryRun {
    if !doSwap && builtinPos == nil {
        print("Would rotate only (external displays stay in place):")
    } else if builtinPos != nil {
        print("Would reposition built-in only (external displays unchanged):")
    } else {
        let desc = noAlign ? "swap (no alignment)" : "align \(alignment.rawValue) + swap"
        print("Would \(desc):")
        print("  Left : id=\(right.id)  origin=(\(swapLeftX), \(swapLeftY))")
        print("  Right: id=\(left.id)  origin=(\(swapRightX), \(swapRightY))")
    }
    if let (bx, by) = builtinOrigin, let b = builtinDisplay {
        print("  Built-in: id=\(b.id)  origin=(\(bx), \(by))  [\(builtinPos!.rawValue) of external group]")
    }
    if let r = rotateLeft  { print("  Rotate left slot:  id=\(finalLeftID)  → \(Int(r.degrees))° (\(r.rawValue))") }
    if let r = rotateRight { print("  Rotate right slot: id=\(finalRightID) → \(Int(r.degrees))° (\(r.rawValue))") }
    print()
    print("(dry-run — no changes applied)")
    exit(0)
}

// MARK: - Apply configuration (single atomic transaction)

var configRef: CGDisplayConfigRef?
var err = CGBeginDisplayConfiguration(&configRef)
guard err == .success, let cfg = configRef else {
    printError("CGBeginDisplayConfiguration failed (code \(err.rawValue))")
    exit(1)
}

// Queues a display-mode change (refresh rate) within the open config.
func applyMode(refreshOutcome: RefreshOutcome, for displayID: CGDirectDisplayID) {
    guard case .found(let mode) = refreshOutcome else { return }
    CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil)
}

if doSwap {
    CGConfigureDisplayOrigin(cfg, right.id, swapLeftX,  swapLeftY)   // right → left slot
    CGConfigureDisplayOrigin(cfg, left.id,  swapRightX, swapRightY)  // left  → right slot
    applyMode(refreshOutcome: leftRefresh,  for: left.id)
    applyMode(refreshOutcome: rightRefresh, for: right.id)
} else {
    applyMode(refreshOutcome: leftRefresh,  for: left.id)
    applyMode(refreshOutcome: rightRefresh, for: right.id)
}

// Position the built-in display if requested.
if let (bx, by) = builtinOrigin, let b = builtinDisplay {
    CGConfigureDisplayOrigin(cfg, b.id, bx, by)
}

err = CGCompleteDisplayConfiguration(cfg, .forSession)
if err == .success {
    if doSwap {
        let alignDesc = noAlign ? "" : " and aligned (\(alignment.rawValue))"
        print("✓ Displays swapped\(alignDesc).")
    }
    if !noRefresh {
        let needsChange = [leftRefresh, rightRefresh].contains {
            if case .found = $0 { return true }; return false
        }
        if needsChange { print("✓ Refresh rate set to \(Int(targetHz)) Hz.") }
    }
    if builtinOrigin != nil {
        print("✓ Built-in display positioned (\(builtinPos!.rawValue) of external group).")
    }

    // Apply rotation changes (outside the atomic config transaction).
    // Rotation flags suppress the swap, so finalLeftID = left.id and
    // finalRightID = right.id — each flag targets exactly the display
    // currently in that slot.
    if rotateLeft != nil || rotateRight != nil {
        guard let rotFn = _setDisplayRotation else {
            printError("Display rotation API not available on this system.")
            exit(1)
        }
        if let r = rotateLeft {
            let result = rotFn(finalLeftID, r.degrees)
            if result == 0 {
                print("✓ Left display rotated to \(Int(r.degrees))° (\(r.rawValue)).")
            } else {
                printError("Failed to rotate left display (code \(result)).")
            }
        }
        if let r = rotateRight {
            let result = rotFn(finalRightID, r.degrees)
            if result == 0 {
                print("✓ Right display rotated to \(Int(r.degrees))° (\(r.rawValue)).")
            } else {
                printError("Failed to rotate right display (code \(result)).")
            }
        }
    }
} else {
    printError("CGCompleteDisplayConfiguration failed (code \(err.rawValue))")
    CGCancelDisplayConfiguration(cfg)
    exit(1)
}
