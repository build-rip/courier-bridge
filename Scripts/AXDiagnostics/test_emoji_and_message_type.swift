#!/usr/bin/env swift
// =============================================================================
// test_emoji_and_message_type.swift
// =============================================================================
//
// PURPOSE:
// Determine whether emoji-heavy messages (like Wordle scores with colored
// square emojis) cause AXShowMenu to produce the wrong context menu (TEXT-EDIT
// instead of tapback). Also compare behavior across different message types
// and between invoking AXShowMenu on the parent row vs. the balloon directly.
//
// BACKGROUND:
// After discovering that AXShowMenu was unreliable for tapbacks, we initially
// suspected that emoji content might be the trigger — Wordle scores contain
// many emoji characters (colored squares) and were among the messages that
// sometimes produced TEXT-EDIT menus. This script was written to isolate
// whether emoji content is the differentiating factor.
//
// WHAT IT DOES:
// 1. Finds all Wordle messages (emoji-heavy, start with "Wordle")
// 2. For each one, tests AXShowMenu on BOTH the parent row element AND the
//    balloon (CKBalloonTextView) directly
// 3. Checks whether the tapback menu appeared (by looking for a "heart"
//    menu item) or a text-editing menu appeared instead
// 4. Also checks whether text got selected in the balloon (AXSelectedText),
//    which would indicate the TEXT-EDIT menu was triggered
// 5. Uses x-position heuristic (x > 900 = right-aligned = sent message)
//    to label messages as "sent" or "received"
// 6. Also tests plain text messages ("Ping pong", "Hey") for comparison
//
// RESULTS:
// - Emoji content was NOT the differentiating factor
// - Some Wordle messages got tapback menus, others got TEXT-EDIT menus
// - The "Ping pong" message ALWAYS got a TEXT-EDIT menu regardless of
//   approach (parent vs balloon, timing, etc.)
// - "Hey" ALWAYS got a tapback menu
// - The pattern was MESSAGE-SPECIFIC, not content-type-specific
// - No text selection was observed in any case
// - Both parent row and balloon direct invocation produced the same result
//   for any given message — suggesting the issue is intrinsic to the message
//   element, not the invocation target
//
// CONCLUSION:
// AXShowMenu is inherently unreliable for triggering tapback menus on certain
// messages. The root cause was never fully identified (possibly related to
// internal Messages.app state or the message's position in the data model).
// This finding led to the discovery of DIRECT CUSTOM AX ACTIONS on each
// CKBalloonTextView (e.g., "Name:Heart\nTarget:0x0\nSelector:(null)") which
// are 100% reliable on ALL messages regardless of content type.
//
// HOW TO RUN:
//   chmod +x Scripts/AXDiagnostics/test_emoji_and_message_type.swift
//   swift Scripts/AXDiagnostics/test_emoji_and_message_type.swift
//
// PREREQUISITES:
// - Messages.app must be running with a chat open
// - The process must have Accessibility permissions
// - The chat should contain Wordle messages and optionally "Ping pong"/"Hey"
//
// =============================================================================

import AppKit
import ApplicationServices

// MARK: - AX Helpers

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

func findBalloons(in element: AXUIElement) -> [AXUIElement] {
    var results: [AXUIElement] = []
    let role: String? = attribute(kAXRoleAttribute, of: element)
    if role == (kAXTextAreaRole as String) {
        let id: String? = attribute(kAXIdentifierAttribute, of: element)
        if id == "CKBalloonTextView" {
            results.append(element)
            return results
        }
    }
    for child in children(of: element) {
        results.append(contentsOf: findBalloons(in: child))
    }
    return results
}

func findMenuItems(in element: AXUIElement) -> [AXUIElement] {
    var results: [AXUIElement] = []
    let role: String? = attribute(kAXRoleAttribute, of: element)
    if role == (kAXMenuItemRole as String) { results.append(element) }
    for child in children(of: element) {
        results.append(contentsOf: findMenuItems(in: child))
    }
    return results
}

/// Check if the tapback menu is open by looking for a "heart" menu item.
/// The tapback menu exposes items with identifiers like "heart", "thumbs_up", etc.
/// A TEXT-EDIT context menu has items like "Cut", "Copy", "Paste" instead.
func hasTapbackMenu(in app: AXUIElement) -> Bool {
    findMenuItems(in: app).contains { (attribute(kAXIdentifierAttribute, of: $0) as String?) == "heart" }
}

/// Dismiss any open menu by synthesizing an Escape keypress via CGEvent.
func dismissMenu() {
    let esc = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
    let escUp = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
    esc?.post(tap: .cghidEventTap)
    usleep(30_000)
    escUp?.post(tap: .cghidEventTap)
    usleep(500_000)
}

/// Check if any text got selected in a balloon (would indicate TEXT-EDIT behavior).
func checkSelectedText(of element: AXUIElement) -> String? {
    attribute(kAXSelectedTextAttribute, of: element)
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
guard let transcript = findByIdentifier("TranscriptCollectionView", in: window) else {
    print("ERROR: TranscriptCollectionView not found"); exit(1)
}

let balloons = findBalloons(in: transcript)

// --- Test emoji-heavy messages (Wordle scores) ---
let wordleBalloons = balloons.filter { balloon in
    let value: String? = attribute(kAXValueAttribute, of: balloon)
    return value?.hasPrefix("Wordle") == true
}

print("Found \(wordleBalloons.count) Wordle (emoji) messages\n")

for (i, balloon) in wordleBalloons.enumerated() {
    let pos = position(of: balloon)!
    let sz = size(of: balloon)!
    let x = Int(pos.x)
    // x > 900 heuristic: sent messages are right-aligned in Messages.app
    let side = x > 900 ? "sent" : "received"

    print("--- Wordle [\(i)] (\(side), pos=\(x),\(Int(pos.y)), size=\(Int(sz.width))x\(Int(sz.height))) ---")

    let parentRow: AXUIElement = attribute(kAXParentAttribute, of: balloon) ?? balloon
    let parentRole: String = attribute(kAXRoleAttribute, of: parentRow) ?? "?"
    let parentID: String? = attribute(kAXIdentifierAttribute, of: parentRow)
    print("  Parent: [\(parentRole)] id=\(parentID ?? "nil")")

    // Test 1: AXShowMenu on the PARENT ROW (the AXGroup containing the balloon)
    print("  AXShowMenu on parent row...")
    let ok1 = AXUIElementPerformAction(parentRow, kAXShowMenuAction as CFString) == .success
    usleep(300_000)
    let menu1 = ok1 && hasTapbackMenu(in: app)
    let sel1 = checkSelectedText(of: balloon)
    print("    Result: action=\(ok1 ? "OK" : "FAIL"), tapback menu=\(menu1 ? "YES" : "NO"), selected='\(sel1 ?? "none")'")
    dismissMenu()

    // Test 2: AXShowMenu on the BALLOON DIRECTLY (CKBalloonTextView)
    print("  AXShowMenu on balloon...")
    let ok2 = AXUIElementPerformAction(balloon, kAXShowMenuAction as CFString) == .success
    usleep(300_000)
    let menu2 = ok2 && hasTapbackMenu(in: app)
    let sel2 = checkSelectedText(of: balloon)
    print("    Result: action=\(ok2 ? "OK" : "FAIL"), tapback menu=\(menu2 ? "YES" : "NO"), selected='\(sel2 ?? "none")'")
    dismissMenu()

    print()
}

// --- Test plain text messages for comparison ---
let otherTexts = ["Ping pong", "Hey"]
for text in otherTexts {
    guard let balloon = balloons.last(where: { (attribute(kAXValueAttribute, of: $0) as String?) == text }) else {
        print("--- '\(text)': not found, skipping ---\n")
        continue
    }
    let pos = position(of: balloon)!
    let x = Int(pos.x)
    let side = x > 900 ? "sent" : "received"
    let parentRow: AXUIElement = attribute(kAXParentAttribute, of: balloon) ?? balloon
    let parentID: String? = attribute(kAXIdentifierAttribute, of: parentRow)

    print("--- '\(text)' (\(side), parent id=\(parentID ?? "nil")) ---")

    print("  AXShowMenu on parent row...")
    let ok = AXUIElementPerformAction(parentRow, kAXShowMenuAction as CFString) == .success
    usleep(300_000)
    let menu = ok && hasTapbackMenu(in: app)
    let sel = checkSelectedText(of: balloon)
    print("    Result: action=\(ok ? "OK" : "FAIL"), tapback menu=\(menu ? "YES" : "NO"), selected='\(sel ?? "none")'")
    dismissMenu()

    print()
}
