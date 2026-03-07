#!/usr/bin/env swift
// =============================================================================
// test_clipping_and_wait_times.swift
// =============================================================================
//
// PURPOSE:
// Investigate whether message clipping (bottom edge extending past the
// transcript view's visible bounds) or insufficient wait times after
// AXShowMenu cause the tapback menu to fail to appear.
//
// BACKGROUND:
// During development of targeted tapback, we observed that AXShowMenu on
// certain messages produced a TEXT-EDIT context menu instead of the expected
// tapback menu. One hypothesis was that messages partially scrolled off-screen
// (clipped) might behave differently. Another was that the menu items simply
// weren't populated fast enough.
//
// WHAT IT DOES:
// 1. Lists ALL message balloons with their positions, sizes, and whether
//    their bottom edge extends past the transcript view's visible area
//    (marked **CLIPPED**)
// 2. Finds Wordle messages (emoji-heavy, multi-line) which are tall and
//    more likely to be clipped
// 3. Tests AXShowMenu on the LAST (newest) Wordle with progressively longer
//    wait times: 300ms, 500ms, 800ms, 1200ms — checking each time whether
//    the tapback menu (identified by a "heart" menu item) appeared
// 4. If the tapback menu doesn't appear, dumps whatever menus DID appear
//    for diagnostic inspection
// 5. Also tests the FIRST Wordle (likely fully visible) for comparison
//
// RESULTS:
// - Clipping was NOT the cause. In follow-up runs, positions changed and
//   no messages were clipped, yet some still got TEXT-EDIT menus.
// - Wait time was NOT the cause. Even at 1200ms, the wrong menu type appeared.
// - The issue turned out to be MESSAGE-SPECIFIC: some messages always get
//   TEXT-EDIT menus from AXShowMenu, regardless of timing or visibility.
// - This led to the discovery that direct custom AX actions (e.g.,
//   "Name:Heart\nTarget:0x0\nSelector:(null)") on CKBalloonTextView elements
//   are 100% reliable and bypass the menu entirely.
//
// HOW TO RUN:
//   chmod +x Scripts/AXDiagnostics/test_clipping_and_wait_times.swift
//   swift Scripts/AXDiagnostics/test_clipping_and_wait_times.swift
//
// PREREQUISITES:
// - Messages.app must be running with a chat open
// - The process must have Accessibility permissions
//   (System Settings > Privacy & Security > Accessibility)
// - The chat must contain Wordle score messages (text starting with "Wordle")
//
// =============================================================================

import AppKit
import ApplicationServices

// MARK: - AX Helpers (standalone, no dependencies on the main project)

func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard result == .success, let value else { return nil }
    return value as? T
}

func children(of element: AXUIElement) -> [AXUIElement] {
    attribute(kAXChildrenAttribute, of: element) ?? []
}

func position(of element: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
    guard result == .success, let value else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func size(of element: AXUIElement) -> CGSize? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
    guard result == .success, let value else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(value as! AXValue, .cgSize, &s) else { return nil }
    return s
}

func findByIdentifier(_ id: String, in element: AXUIElement) -> AXUIElement? {
    let elemID: String? = attribute(kAXIdentifierAttribute, of: element)
    if elemID == id { return element }
    for child in children(of: element) {
        if let found = findByIdentifier(id, in: child) { return found }
    }
    return nil
}

/// Find all CKBalloonTextView elements (AXTextArea with id="CKBalloonTextView").
/// These are the message bubble text views in Messages.app's transcript.
func findBalloons(in element: AXUIElement) -> [AXUIElement] {
    var results: [AXUIElement] = []
    let role: String? = attribute(kAXRoleAttribute, of: element)
    if role == (kAXTextAreaRole as String) {
        let id: String? = attribute(kAXIdentifierAttribute, of: element)
        if id == "CKBalloonTextView" {
            results.append(element)
            return results  // No need to recurse into text areas
        }
    }
    for child in children(of: element) {
        results.append(contentsOf: findBalloons(in: child))
    }
    return results
}

/// Find all AXMenuItem elements in the tree (used to check what menu appeared).
func findMenuItems(in element: AXUIElement) -> [AXUIElement] {
    var results: [AXUIElement] = []
    let role: String? = attribute(kAXRoleAttribute, of: element)
    if role == (kAXMenuItemRole as String) { results.append(element) }
    for child in children(of: element) {
        results.append(contentsOf: findMenuItems(in: child))
    }
    return results
}

/// Find all AXMenu elements in the tree.
func findMenus(in element: AXUIElement) -> [AXUIElement] {
    var results: [AXUIElement] = []
    let role: String? = attribute(kAXRoleAttribute, of: element)
    if role == (kAXMenuRole as String) { results.append(element) }
    for child in children(of: element) {
        results.append(contentsOf: findMenus(in: child))
    }
    return results
}

/// Dismiss any open menu by pressing Escape.
func dismissMenu() {
    let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
    let escUp = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
    esc?.post(tap: .cghidEventTap)
    usleep(30_000)
    escUp?.post(tap: .cghidEventTap)
    usleep(500_000)  // Wait for menu dismiss animation
}

/// Dump a subtree of the AX hierarchy for diagnostic output.
func dumpTree(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 4) {
    guard depth < maxDepth else { return }
    let indent = String(repeating: "  ", count: depth)
    let role: String = attribute(kAXRoleAttribute, of: element) ?? "?"
    let title: String? = attribute(kAXTitleAttribute, of: element)
    let id: String? = attribute(kAXIdentifierAttribute, of: element)
    var line = "\(indent)[\(role)]"
    if let title, !title.isEmpty { line += " title=\"\(title.prefix(50))\"" }
    if let id, !id.isEmpty { line += " id=\"\(id)\"" }
    print(line)
    for child in children(of: element) {
        dumpTree(child, depth: depth + 1, maxDepth: maxDepth)
    }
}

// MARK: - Main

guard AXIsProcessTrusted() else { print("ERROR: No accessibility permission"); exit(1) }

let apps = NSWorkspace.shared.runningApplications
guard let messages = apps.first(where: { $0.bundleIdentifier == "com.apple.MobileSMS" }) else {
    print("ERROR: Messages not running"); exit(1)
}

let app = AXUIElementCreateApplication(messages.processIdentifier)
let windows = children(of: app).filter { (attribute(kAXRoleAttribute, of: $0) as String?) == (kAXWindowRole as String) }
guard let window = windows.first else { print("ERROR: No window"); exit(1) }

// Print window and transcript geometry for clipping analysis
let windowPos = position(of: window)!
let windowSize = size(of: window)!
print("Window: pos=\(Int(windowPos.x)),\(Int(windowPos.y)) size=\(Int(windowSize.width))x\(Int(windowSize.height))")
print("Window bottom edge: y=\(Int(windowPos.y + windowSize.height))\n")

guard let transcript = findByIdentifier("TranscriptCollectionView", in: window) else {
    print("ERROR: TranscriptCollectionView not found"); exit(1)
}

let transcriptPos = position(of: transcript)!
let transcriptSize = size(of: transcript)!
print("Transcript: pos=\(Int(transcriptPos.x)),\(Int(transcriptPos.y)) size=\(Int(transcriptSize.width))x\(Int(transcriptSize.height))")
print("Transcript bottom edge: y=\(Int(transcriptPos.y + transcriptSize.height))\n")

let balloons = findBalloons(in: transcript)
let wordleBalloons = balloons.filter { (attribute(kAXValueAttribute, of: $0) as String?)?.hasPrefix("Wordle") == true }

// List all balloons with clipping status
print("All balloons and their positions:")
for (i, balloon) in balloons.enumerated() {
    let value: String? = attribute(kAXValueAttribute, of: balloon)
    let pos = position(of: balloon)!
    let sz = size(of: balloon)!
    let bottomEdge = pos.y + sz.height
    let isClipped = bottomEdge > transcriptPos.y + transcriptSize.height
    let short = (value ?? "").prefix(30).replacingOccurrences(of: "\n", with: "\\n")
    print("  [\(i)] \"\(short)\" pos=\(Int(pos.x)),\(Int(pos.y)) bottom=\(Int(bottomEdge))\(isClipped ? " **CLIPPED**" : "")")
}

// Test the last (newest) Wordle with increasing wait times
print("\n=== Testing last Wordle with increased wait times ===\n")

guard let lastWordle = wordleBalloons.last else {
    print("ERROR: No Wordle found"); exit(1)
}

let lwPos = position(of: lastWordle)!
let lwSize = size(of: lastWordle)!
print("Last Wordle: pos=\(Int(lwPos.x)),\(Int(lwPos.y)) size=\(Int(lwSize.width))x\(Int(lwSize.height)) bottom=\(Int(lwPos.y + lwSize.height))")

let parentRow: AXUIElement = attribute(kAXParentAttribute, of: lastWordle) ?? lastWordle

// Progressive wait time test: does waiting longer help the tapback menu appear?
for waitMs in [300, 500, 800, 1200] {
    print("\nTest: AXShowMenu on parent, wait \(waitMs)ms...")
    let ok = AXUIElementPerformAction(parentRow, kAXShowMenuAction as CFString) == .success
    usleep(UInt32(waitMs) * 1000)

    let items = findMenuItems(in: app)
    let hasHeart = items.contains { (attribute(kAXIdentifierAttribute, of: $0) as String?) == "heart" }

    if hasHeart {
        print("  Tapback menu: YES (\(items.count) total menu items)")
    } else {
        print("  Tapback menu: NO (\(items.count) total menu items)")
        // Dump whatever menus DID appear so we can see what went wrong
        let menus = findMenus(in: window)
        if menus.isEmpty {
            print("  No menus found in window at all")
            let appMenus = findMenus(in: app)
            print("  Menus at app level: \(appMenus.count)")
        }
        for menu in menus {
            print("  Menu found:")
            dumpTree(menu, maxDepth: 3)
        }
    }

    dismissMenu()
}

// Compare against a fully visible Wordle (the first one, near the top)
print("\n=== Test: AXShowMenu on a fully visible Wordle ===\n")
if let firstWordle = wordleBalloons.first {
    let fwPos = position(of: firstWordle)!
    print("First Wordle: pos=\(Int(fwPos.x)),\(Int(fwPos.y))")
    let fwParent: AXUIElement = attribute(kAXParentAttribute, of: firstWordle) ?? firstWordle
    let ok = AXUIElementPerformAction(fwParent, kAXShowMenuAction as CFString) == .success
    usleep(300_000)
    let items = findMenuItems(in: app)
    let hasHeart = items.contains { (attribute(kAXIdentifierAttribute, of: $0) as String?) == "heart" }
    print("  AXShowMenu: \(ok ? "OK" : "FAIL"), tapback: \(hasHeart ? "YES" : "NO")")
    dismissMenu()
}
