import ApplicationServices
import Foundation
import AppKit

// MARK: - EmojiPosition

public struct EmojiPosition: Sendable {
    public let emoji: String
    public let scrollPosition: Double  // 0.0-1.0 scroll bar value

    public init(emoji: String, scrollPosition: Double) {
        self.emoji = emoji
        self.scrollPosition = scrollPosition
    }
}

// MARK: - Errors

public enum UIAutomationError: Error, CustomStringConvertible {
    case messagesNotRunning
    case transcriptNotFound
    case messageNotFound(text: String)
    case partNotFound(partIndex: Int)
    case tapbackMenuNotFound
    case accessibilityNotPermitted
    case emojiPickerFailed(reason: String)
    case waitTimeout(description: String)

    public var description: String {
        switch self {
        case .messagesNotRunning:
            return "Messages.app is not running"
        case .transcriptNotFound:
            return "Could not find the message transcript in Messages.app"
        case .messageNotFound(let text):
            return "Could not find message with text: \(text.prefix(50))"
        case .partNotFound(let partIndex):
            return "Could not find part \(partIndex) in the message"
        case .tapbackMenuNotFound:
            return "Could not find the tapback menu"
        case .accessibilityNotPermitted:
            return "Accessibility permission not granted. Enable it in System Settings > Privacy & Security > Accessibility."
        case .emojiPickerFailed(let reason):
            return "Emoji picker failed: \(reason)"
        case .waitTimeout(let description):
            return "Timed out waiting for: \(description)"
        }
    }
}

// MARK: - UIAutomation

/// UI automation for typing indicators and tapbacks using accessibility APIs.
public struct UIAutomation: Sendable {
    private let ax = AccessibilityHelper()

    public init() {}

    /// Type text character-by-character into the Messages compose field.
    public func typeText(_ text: String, chatIdentifier: String) async throws {
        try await activateChat(chatIdentifier: chatIdentifier)

        let script = """
            tell application "System Events"
                tell process "Messages"
                    keystroke "\(escapeForAppleScript(text))"
                end tell
            end tell
            """
        try await runOsascript(script)
    }

    /// Send a tapback reaction on a specific message identified by its text content.
    /// Uses Accessibility APIs to find the message in the UI and trigger the reaction.
    public func sendTargetedTapback(
        _ type: TapbackType,
        messageText: String,
        chatIdentifier: String
    ) async throws {
        guard ax.isAccessibilityTrusted() else {
            throw UIAutomationError.accessibilityNotPermitted
        }

        // Activate Messages and navigate to the chat
        try await activateChat(chatIdentifier: chatIdentifier)

        guard let app = ax.messagesApp() else {
            throw UIAutomationError.messagesNotRunning
        }

        // Find the transcript collection view (contains message bubbles)
        let transcript = try findTranscriptView(in: app)

        // Find the target message by its text content, searching newest-first
        let messageElement = try findMessage(withText: messageText, in: transcript)

        // Right-click the message to open the context menu, then select the tapback
        try await triggerTapback(type, on: messageElement)
    }

    /// Send a tapback reaction targeting a specific part (attachment) of a message.
    /// `partIndex` is 1+ for attachments. The message is found by text (if available)
    /// or by scanning balloon elements within the message row.
    public func sendTargetedTapback(
        _ type: TapbackType,
        messageText: String?,
        partIndex: Int,
        chatIdentifier: String
    ) async throws {
        guard ax.isAccessibilityTrusted() else {
            throw UIAutomationError.accessibilityNotPermitted
        }

        try await activateChat(chatIdentifier: chatIdentifier)

        guard let app = ax.messagesApp() else {
            throw UIAutomationError.messagesNotRunning
        }

        let transcript = try findTranscriptView(in: app)

        // Find the message row containing the target, then find the right part
        let targetElement = try findMessagePart(
            withText: messageText,
            partIndex: partIndex,
            in: transcript
        )

        try await triggerTapback(type, on: targetElement)
    }

    /// Send an emoji tapback reaction on a message.
    /// First tries the emoji as a direct custom action (works for recently used emoji).
    /// If not available, opens the emoji picker, searches by Unicode name, and selects it.
    public func sendEmojiTapback(
        emoji: String,
        messageText: String,
        chatIdentifier: String,
        cachedPosition: EmojiPosition? = nil
    ) async throws {
        guard ax.isAccessibilityTrusted() else {
            throw UIAutomationError.accessibilityNotPermitted
        }

        try await activateChat(chatIdentifier: chatIdentifier)

        guard let app = ax.messagesApp() else {
            throw UIAutomationError.messagesNotRunning
        }

        let transcript = try findTranscriptView(in: app)
        let balloon = try findMessage(withText: messageText, in: transcript)
        try await triggerEmojiTapback(emoji, on: balloon, in: app, cachedPosition: cachedPosition)
    }

    /// Send an emoji tapback reaction targeting a specific part of a message.
    public func sendEmojiTapback(
        emoji: String,
        messageText: String?,
        partIndex: Int,
        chatIdentifier: String,
        cachedPosition: EmojiPosition? = nil
    ) async throws {
        guard ax.isAccessibilityTrusted() else {
            throw UIAutomationError.accessibilityNotPermitted
        }

        try await activateChat(chatIdentifier: chatIdentifier)

        guard let app = ax.messagesApp() else {
            throw UIAutomationError.messagesNotRunning
        }

        let transcript = try findTranscriptView(in: app)
        let balloon = try findMessagePart(
            withText: messageText,
            partIndex: partIndex,
            in: transcript
        )
        try await triggerEmojiTapback(emoji, on: balloon, in: app, cachedPosition: cachedPosition)
    }

    /// Mark a chat as read by activating it in Messages.app.
    /// Opening a chat in Messages causes macOS to mark all messages as read
    /// and send read receipts to the sender.
    public func markChatAsRead(chatIdentifier: String) async throws {
        try await activateChat(chatIdentifier: chatIdentifier)
    }

    /// Dump the accessibility tree of Messages.app for diagnostic purposes.
    public func dumpMessagesAccessibilityTree(maxDepth: Int = 8) -> String {
        guard ax.isAccessibilityTrusted() else {
            return "ERROR: Accessibility permission not granted"
        }
        guard let app = ax.messagesApp() else {
            return "ERROR: Messages.app is not running"
        }
        return ax.dumpTree(of: app, maxDepth: maxDepth)
    }

    /// Press Enter to send the currently typed text.
    public func pressEnter() async throws {
        let script = """
            tell application "System Events"
                tell process "Messages"
                    keystroke return
                end tell
            end tell
            """
        try await runOsascript(script)
    }

    // MARK: - Targeted Tapback Internals

    /// Find the transcript collection view within the Messages window.
    /// Identified by id="TranscriptCollectionView" in the AX tree.
    private func findTranscriptView(in app: AXUIElement) throws -> AXUIElement {
        let windows = ax.children(of: app, withRole: kAXWindowRole as String)
        guard let window = windows.first else {
            throw UIAutomationError.transcriptNotFound
        }

        // Search for the group with identifier "TranscriptCollectionView"
        if let transcript = findElementByIdentifier(
            "TranscriptCollectionView", in: window
        ) {
            return transcript
        }

        throw UIAutomationError.transcriptNotFound
    }

    /// Recursively find an element by its AX identifier.
    private func findElementByIdentifier(
        _ identifier: String, in element: AXUIElement
    ) -> AXUIElement? {
        let elementID: String? = ax.attribute(kAXIdentifierAttribute, of: element)
        if elementID == identifier {
            return element
        }
        for child in ax.children(of: element) {
            if let found = findElementByIdentifier(identifier, in: child) {
                return found
            }
        }
        return nil
    }

    /// Find a message balloon (AXTextArea) matching the given text within the transcript.
    /// Returns the balloon element directly — custom actions for tapbacks are on the balloon itself.
    private func findMessage(withText text: String, in transcript: AXUIElement) throws -> AXUIElement {
        let balloons = findBalloonTextViews(in: transcript)
        // Strip U+FFFC (attachment placeholder) — the AX tree doesn't include them
        let cleanText = text.replacingOccurrences(of: "\u{FFFC}", with: "")

        // Search from end (newest) to beginning (oldest) for matching text
        for balloon in balloons.reversed() {
            let value: String? = ax.attribute(kAXValueAttribute, of: balloon)
            if value == cleanText {
                return balloon
            }
        }

        // If exact match fails, try prefix matching for long/truncated messages
        for balloon in balloons.reversed() {
            let value: String? = ax.attribute(kAXValueAttribute, of: balloon)
            if let value, !value.isEmpty,
               cleanText.hasPrefix(value) || value.hasPrefix(cleanText) {
                return balloon
            }
        }

        throw UIAutomationError.messageNotFound(text: text)
    }

    /// Find all AXTextArea elements with id="CKBalloonTextView" in the tree.
    private func findBalloonTextViews(in element: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []
        let role: String? = ax.attribute(kAXRoleAttribute, of: element)
        if role == (kAXTextAreaRole as String) {
            let identifier: String? = ax.attribute(kAXIdentifierAttribute, of: element)
            if identifier == "CKBalloonTextView" {
                results.append(element)
                return results  // No need to recurse into text areas
            }
        }
        for child in ax.children(of: element) {
            results.append(contentsOf: findBalloonTextViews(in: child))
        }
        return results
    }

    /// Find a specific part (balloon) within a message for tapback targeting.
    /// First locates the message row by text content, then finds the Nth balloon element.
    private func findMessagePart(
        withText text: String?,
        partIndex: Int,
        in transcript: AXUIElement
    ) throws -> AXUIElement {
        // Strategy: find the message row containing our text balloon, then
        // enumerate all balloon elements within that row and pick by index.
        let balloons = findBalloonTextViews(in: transcript)

        // Find the text balloon matching our message (newest first)
        var matchedBalloon: AXUIElement?
        if let text, !text.isEmpty {
            for balloon in balloons.reversed() {
                let value: String? = ax.attribute(kAXValueAttribute, of: balloon)
                if value == text {
                    matchedBalloon = balloon
                    break
                }
            }
            // Prefix fallback
            if matchedBalloon == nil {
                for balloon in balloons.reversed() {
                    let value: String? = ax.attribute(kAXValueAttribute, of: balloon)
                    if let value, !value.isEmpty,
                       text.hasPrefix(value) || value.hasPrefix(text) {
                        matchedBalloon = balloon
                        break
                    }
                }
            }
        }

        // Walk up from the matched balloon to find the message row container,
        // then find all balloon children (text + image) at the right index.
        if let matched = matchedBalloon {
            // Walk up to the message row — look for the row-level group
            let messageRow = findMessageRow(from: matched)

            // Find all balloon elements within this row
            let rowBalloons = findAllBalloonViews(in: messageRow)

            if partIndex < rowBalloons.count {
                return rowBalloons[partIndex]
            }

            // If index is out of range, try the matched balloon's parent as fallback
            throw UIAutomationError.partNotFound(partIndex: partIndex)
        }

        // No text match — can't locate the message row
        throw UIAutomationError.messageNotFound(text: text ?? "(no text)")
    }

    /// Walk up the AX tree from an element to find the message row container.
    /// Stops at the first element with identifier containing "Row" or after 5 levels.
    private func findMessageRow(from element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<5 {
            guard let parent: AXUIElement = ax.attribute(kAXParentAttribute, of: current) else {
                return current
            }
            let identifier: String? = ax.attribute(kAXIdentifierAttribute, of: parent)
            // TranscriptCollectionView is the top — stop before it
            if identifier == "TranscriptCollectionView" {
                return current
            }
            current = parent
        }
        return current
    }

    /// Find all balloon view elements (text and image) within a message row.
    /// Looks for CKBalloonTextView (text) and CKBalloonImageView (images).
    private func findAllBalloonViews(in element: AXUIElement) -> [AXUIElement] {
        var results: [AXUIElement] = []
        let identifier: String? = ax.attribute(kAXIdentifierAttribute, of: element)
        if let identifier,
           identifier == "CKBalloonTextView" || identifier == "CKBalloonImageView" {
            results.append(element)
            return results
        }
        for child in ax.children(of: element) {
            results.append(contentsOf: findAllBalloonViews(in: child))
        }
        return results
    }

    /// Trigger a tapback on a message balloon element using its custom AX action.
    /// Each CKBalloonTextView exposes named actions like "Name:Heart\nTarget:0x0\nSelector:(null)"
    /// that can be invoked directly — no context menu needed.
    private func triggerTapback(_ type: TapbackType, on balloon: AXUIElement) async throws {
        let actionName = type.customActionName

        // Try the direct custom action on the balloon
        if ax.performAction(actionName, on: balloon) {
            return
        }

        // If the custom action failed, try on the parent row
        if let parent: AXUIElement = ax.attribute(kAXParentAttribute, of: balloon) {
            if ax.performAction(actionName, on: parent) {
                return
            }
        }

        throw UIAutomationError.tapbackMenuNotFound
    }

    // MARK: - Emoji Tapback Internals

    /// Try to send an emoji tapback on a balloon element.
    /// First attempts the direct custom action (for recently used emoji),
    /// then falls back to the emoji picker search flow.
    private func triggerEmojiTapback(
        _ emoji: String,
        on balloon: AXUIElement,
        in app: AXUIElement,
        cachedPosition: EmojiPosition? = nil
    ) async throws {
        // Strategy 1: Try direct custom action (works for recently used emoji)
        let directAction = "Name:\(emoji)\nTarget:0x0\nSelector:(null)"
        let balloonActions = ax.actionNames(of: balloon)
        if balloonActions.contains(directAction) {
            ax.performAction(directAction, on: balloon)
            return
        }

        // Strategy 2: Use the emoji picker
        try await sendEmojiViaPicker(emoji, on: balloon, in: app, cachedPosition: cachedPosition)
    }

    /// Open the emoji picker popover, find the emoji button in the grid, and press it.
    private func sendEmojiViaPicker(
        _ emoji: String,
        on balloon: AXUIElement,
        in app: AXUIElement,
        cachedPosition: EmojiPosition? = nil
    ) async throws {
        let window = ax.children(of: app, withRole: kAXWindowRole as String).first!

        // Open the emoji picker
        ax.performAction(
            "Name:Add Emoji as Tapback\nTarget:0x0\nSelector:(null)",
            on: balloon
        )
        try await waitUntil(timeout: .seconds(5), description: "tapback picker or emoji popover to appear") {
            !findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
            || findElementByIdentifier("TapbackPickerCollectionView", in: window) != nil
        }

        // If we got the tapback picker overlay instead of the full popover,
        // press the "Add custom emoji reaction" button to open the full picker
        if findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
            && findElementByIdentifier("TapbackPickerCollectionView", in: window) != nil
        {
            if let addBtn = findElementByDescription("Add custom emoji reaction", in: window) {
                ax.performAction(kAXPressAction as String, on: addBtn)
                try await waitUntil(timeout: .seconds(5), description: "emoji picker popover to appear") {
                    !findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
                }
            }
        }

        guard let popover = findElementsByRole("AXPopover", in: window, maxDepth: 3).first else {
            dismissOverlays(in: window)
            throw UIAutomationError.emojiPickerFailed(reason: "Could not open emoji picker popover")
        }

        // Fast path: use cached position to jump directly to the emoji
        if let cached = cachedPosition {
            if let btn = findEmojiButtonViaCachedPosition(emoji, cachedPosition: cached, in: popover) {
                ax.performAction(kAXPressAction as String, on: btn)
                try await waitUntil(timeout: .seconds(5), description: "emoji reaction to be applied") {
                    findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
                }
                dismissOverlays(in: window)
                return
            }
            // Cache miss — fall through to slow path
        }

        // Click a category button to ensure we're in browse mode (not search mode).
        // In browse mode, every emoji is an AXButton with desc matching the emoji character.
        if let categoryBtn = findElementByDescription("people", in: popover) {
            ax.performAction(kAXPressAction as String, on: categoryBtn)
            try await waitUntil(timeout: .seconds(5), description: "emoji buttons to appear in picker") {
                !findAllEmojiButtons(in: popover).isEmpty
            }
        }

        // Find the emoji button, scrolling through the grid if needed since the
        // picker virtualizes its content and only exposes visible emoji as AX elements.
        guard let emojiBtn = findEmojiButtonWithScroll(emoji, in: popover) else {
            dismissOverlays(in: window)
            throw UIAutomationError.emojiPickerFailed(reason: "Emoji '\(emoji)' not found in picker")
        }

        ax.performAction(kAXPressAction as String, on: emojiBtn)
        try await waitUntil(timeout: .seconds(5), description: "emoji reaction to be applied") {
            findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
        }

        // Clean up any remaining overlays
        dismissOverlays(in: window)
    }

    /// Find an AXButton whose description matches the given emoji character.
    private func findEmojiButton(
        _ emoji: String,
        in element: AXUIElement,
        maxDepth: Int = 15,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        let role: String? = ax.attribute(kAXRoleAttribute, of: element)
        if role == kAXButtonRole as String {
            let desc: String? = ax.attribute(kAXDescriptionAttribute, of: element)
            if desc == emoji { return element }
            // AXButtons that are emoji have no children to recurse into
            return nil
        }
        for child in ax.children(of: element) {
            if let found = findEmojiButton(emoji, in: child, maxDepth: maxDepth, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// Find an emoji button in the picker, scrolling through the grid if not immediately visible.
    /// The emoji picker virtualizes its grid, so only on-screen emoji are in the AX tree.
    private func findEmojiButtonWithScroll(
        _ emoji: String,
        in popover: AXUIElement,
        maxScrollAttempts: Int = 20
    ) -> AXUIElement? {
        // Check if already visible
        if let btn = findEmojiButton(emoji, in: popover) {
            return btn
        }

        // Find the scroll area inside the popover to target scroll events at it
        guard let scrollArea = findElementsByRole(kAXScrollAreaRole as String, in: popover, maxDepth: 6).first,
              let pos = ax.position(of: scrollArea),
              let size = ax.size(of: scrollArea) else {
            return nil
        }

        // Target the center of the scroll area
        let scrollX = pos.x + size.width / 2
        let scrollY = pos.y + size.height / 2

        for _ in 0..<maxScrollAttempts {
            // Scroll down by a chunk
            if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: -5,  // negative = scroll down
                wheel2: 0,
                wheel3: 0
            ) {
                scrollEvent.location = CGPoint(x: scrollX, y: scrollY)
                scrollEvent.post(tap: .cghidEventTap)
            }

            if let btn = findEmojiButton(emoji, in: popover) {
                return btn
            }
        }

        return nil
    }

    /// Dismiss any open overlays (tapback picker, emoji picker popover).
    /// Clicks outside the picker bounds to dismiss it, since AX cancel actions
    /// don't reliably close the emoji picker.
    private func dismissOverlays(in window: AXUIElement) {
        for _ in 0..<3 {
            let hasPopover = !findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
            let hasTapback = findElementByIdentifier("TapbackPickerCollectionView", in: window) != nil
            guard hasPopover || hasTapback else { break }

            // Click in the window area outside the picker to dismiss it
            if let windowPos = ax.position(of: window) {
                // Click near the top-left of the window, away from any picker
                let clickX = windowPos.x + 50
                let clickY = windowPos.y + 50
                if let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left),
                   let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left) {
                    mouseDown.post(tap: .cghidEventTap)
                    mouseUp.post(tap: .cghidEventTap)
                }
            }
            let dismissed = waitUntilSync(timeout: 2.0) {
                findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
                && findElementByIdentifier("TapbackPickerCollectionView", in: window) == nil
            }
            if dismissed { break }
        }
    }

    /// Recursively find an element by its AX description.
    private func findElementByDescription(
        _ description: String,
        in element: AXUIElement,
        maxDepth: Int = 15,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        let desc: String? = ax.attribute(kAXDescriptionAttribute, of: element)
        if desc == description { return element }
        for child in ax.children(of: element) {
            if let found = findElementByDescription(
                description, in: child, maxDepth: maxDepth, depth: depth + 1
            ) {
                return found
            }
        }
        return nil
    }

    /// Recursively find all elements matching a given role.
    private func findElementsByRole(
        _ role: String,
        in element: AXUIElement,
        maxDepth: Int = 15,
        depth: Int = 0
    ) -> [AXUIElement] {
        guard depth < maxDepth else { return [] }
        var results: [AXUIElement] = []
        let elementRole: String? = ax.attribute(kAXRoleAttribute, of: element)
        if elementRole == role { results.append(element) }
        for child in ax.children(of: element) {
            results.append(contentsOf: findElementsByRole(
                role, in: child, maxDepth: maxDepth, depth: depth + 1
            ))
        }
        return results
    }

    // MARK: - Emoji Position Indexing

    /// Find the vertical AXScrollBar within a scroll area.
    private func findVerticalScrollBar(in scrollArea: AXUIElement) -> AXUIElement? {
        for child in ax.children(of: scrollArea) {
            let role: String? = ax.attribute(kAXRoleAttribute, of: child)
            guard role == (kAXScrollBarRole as String) else { continue }
            let orientation: String? = ax.attribute(kAXOrientationAttribute, of: child)
            if orientation == (kAXVerticalOrientationValue as String) {
                return child
            }
        }
        return nil
    }

    /// Collect all visible emoji buttons in an element, returning (emoji, element) pairs.
    private func findAllEmojiButtons(in element: AXUIElement, maxDepth: Int = 15, depth: Int = 0) -> [(String, AXUIElement)] {
        guard depth < maxDepth else { return [] }
        var results: [(String, AXUIElement)] = []
        let role: String? = ax.attribute(kAXRoleAttribute, of: element)
        if role == kAXButtonRole as String {
            if let desc: String = ax.attribute(kAXDescriptionAttribute, of: element),
               !desc.isEmpty, desc.unicodeScalars.count <= 10 {
                // Emoji buttons have short descriptions that are the emoji character(s)
                results.append((desc, element))
            }
            return results
        }
        for child in ax.children(of: element) {
            results.append(contentsOf: findAllEmojiButtons(in: child, maxDepth: maxDepth, depth: depth + 1))
        }
        return results
    }

    /// Try to find an emoji button using a cached scroll position.
    /// Sets scroll bar value directly, then looks for the button.
    /// On miss, tries 3 small forward nudges before giving up.
    private func findEmojiButtonViaCachedPosition(
        _ emoji: String,
        cachedPosition: EmojiPosition,
        in popover: AXUIElement
    ) -> AXUIElement? {
        // Find scroll area and its scroll bar
        guard let scrollArea = findElementsByRole(kAXScrollAreaRole as String, in: popover, maxDepth: 6).first,
              let scrollBar = findVerticalScrollBar(in: scrollArea) else {
            return nil
        }

        // Set the scroll bar value to the cached position
        ax.setAttribute(kAXValueAttribute, value: cachedPosition.scrollPosition as CFTypeRef, on: scrollBar)

        // Check if the emoji is visible
        if let btn = findEmojiButton(emoji, in: popover) {
            return btn
        }

        // Try 3 small forward nudges
        for i in 1...3 {
            let nudged = min(1.0, cachedPosition.scrollPosition + Double(i) * 0.02)
            ax.setAttribute(kAXValueAttribute, value: nudged as CFTypeRef, on: scrollBar)
            if let btn = findEmojiButton(emoji, in: popover) {
                return btn
            }
        }

        return nil
    }

    /// Scan the emoji picker with a single top-to-bottom scroll pass, collecting
    /// all emoji and their scroll positions. The picker is one continuous scroll view;
    /// category buttons just jump to offsets within it.
    public func indexEmojiPicker(chatIdentifier: String) async throws -> [EmojiPosition] {
        guard ax.isAccessibilityTrusted() else {
            throw UIAutomationError.accessibilityNotPermitted
        }

        try await activateChat(chatIdentifier: chatIdentifier)

        guard let app = ax.messagesApp() else {
            throw UIAutomationError.messagesNotRunning
        }

        let transcript = try findTranscriptView(in: app)

        // Find any balloon to open the emoji picker on
        let balloons = findBalloonTextViews(in: transcript)
        guard let balloon = balloons.last else {
            throw UIAutomationError.emojiPickerFailed(reason: "No message balloons found to attach picker to")
        }

        let window = ax.children(of: app, withRole: kAXWindowRole as String).first!

        // Open the emoji picker
        ax.performAction(
            "Name:Add Emoji as Tapback\nTarget:0x0\nSelector:(null)",
            on: balloon
        )
        try await waitUntil(timeout: .seconds(5), description: "tapback picker or emoji popover to appear") {
            !findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
            || findElementByIdentifier("TapbackPickerCollectionView", in: window) != nil
        }

        // If we got the tapback picker overlay, open the full picker
        if findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
            && findElementByIdentifier("TapbackPickerCollectionView", in: window) != nil
        {
            if let addBtn = findElementByDescription("Add custom emoji reaction", in: window) {
                ax.performAction(kAXPressAction as String, on: addBtn)
                try await waitUntil(timeout: .seconds(5), description: "emoji picker popover to appear") {
                    !findElementsByRole("AXPopover", in: window, maxDepth: 3).isEmpty
                }
            }
        }

        guard let popover = findElementsByRole("AXPopover", in: window, maxDepth: 3).first else {
            dismissOverlays(in: window)
            throw UIAutomationError.emojiPickerFailed(reason: "Could not open emoji picker popover for indexing")
        }

        // Click a category to ensure we're in browse mode (not search mode)
        if let categoryBtn = findElementByDescription("people", in: popover) {
            ax.performAction(kAXPressAction as String, on: categoryBtn)
            try await waitUntil(timeout: .seconds(5), description: "emoji buttons to appear in picker") {
                !findAllEmojiButtons(in: popover).isEmpty
            }
        }

        guard let scrollArea = findElementsByRole(kAXScrollAreaRole as String, in: popover, maxDepth: 6).first,
              let scrollBar = findVerticalScrollBar(in: scrollArea) else {
            dismissOverlays(in: window)
            throw UIAutomationError.emojiPickerFailed(reason: "Could not find scroll area in emoji picker")
        }

        // Scroll to top
        ax.setAttribute(kAXValueAttribute, value: 0.0 as CFTypeRef, on: scrollBar)

        // Single pass: scroll from top to bottom collecting all emoji
        var allPositions: [EmojiPosition] = []
        var seenEmoji = Set<String>()
        var scrollValue = 0.0

        while scrollValue < 1.0 {
            // Read current scroll bar value
            let currentValue: Any? = ax.attribute(kAXValueAttribute, of: scrollBar)
            if let num = currentValue as? NSNumber {
                scrollValue = num.doubleValue
            }

            // Collect visible emoji at this scroll position
            for (emojiChar, _) in findAllEmojiButtons(in: popover) {
                if !seenEmoji.contains(emojiChar) {
                    seenEmoji.insert(emojiChar)
                    allPositions.append(EmojiPosition(
                        emoji: emojiChar,
                        scrollPosition: scrollValue
                    ))
                }
            }

            // Advance scroll
            let nextValue = min(1.0, scrollValue + 0.20)
            if nextValue == scrollValue { break }
            ax.setAttribute(kAXValueAttribute, value: nextValue as CFTypeRef, on: scrollBar)

            // Check if we actually moved
            let afterScroll: Any? = ax.attribute(kAXValueAttribute, of: scrollBar)
            if let num = afterScroll as? NSNumber, num.doubleValue == scrollValue {
                break  // Reached the end
            }
            scrollValue = nextValue
        }

        // Collect any remaining emoji at final position
        let finalValue: Any? = ax.attribute(kAXValueAttribute, of: scrollBar)
        let finalScroll = (finalValue as? NSNumber)?.doubleValue ?? scrollValue
        for (emojiChar, _) in findAllEmojiButtons(in: popover) {
            if !seenEmoji.contains(emojiChar) {
                seenEmoji.insert(emojiChar)
                allPositions.append(EmojiPosition(
                    emoji: emojiChar,
                    scrollPosition: finalScroll
                ))
            }
        }

        // Close the picker
        dismissOverlays(in: window)

        return allPositions
    }

    // MARK: - Condition Waiting

    /// Poll until condition is true or timeout expires (async).
    private func waitUntil(
        timeout: Duration = .seconds(5),
        interval: Duration = .milliseconds(100),
        description: String = "condition",
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: interval)
        }
        if condition() { return }
        throw UIAutomationError.waitTimeout(description: description)
    }

    /// Poll until condition is true or timeout expires (synchronous). Returns false on timeout.
    private func waitUntilSync(
        timeout: TimeInterval = 5.0,
        interval: TimeInterval = 0.1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return condition()
    }

    // MARK: - Private Helpers

    private func activateChat(chatIdentifier: String) async throws {
        // Chat guid format: "any;-;+16026925091" (1:1) or "any;+;chatXXX" (group)
        // Split on ";" to get [service, type, address]
        let parts = chatIdentifier.split(separator: ";", maxSplits: 2)
        guard parts.count == 3 else {
            // Fallback: just activate Messages without navigating
            try await runOsascript("""
                tell application "Messages"
                    activate
                end tell
                """)
            return
        }

        let chatType = parts[1]  // "-" for 1:1, "+" for group
        let address = String(parts[2])

        let urlString: String
        if chatType == "-" {
            urlString = "\(ServiceAlias.instantSchemeRawValue)://\(address)"
        } else {
            urlString = "\(ServiceAlias.instantSchemeRawValue)://open?groupID=\(address)"
        }

        // Use `do shell script` to run /usr/bin/open via osascript — avoids
        // blocking issues with Process.waitUntilExit in async context
        try await runOsascript("do shell script \"/usr/bin/open '\(urlString)'\"")

        // Wait for Messages to navigate to the chat — poll for TranscriptCollectionView
        try await waitUntil(timeout: .seconds(10), interval: .milliseconds(200), description: "TranscriptCollectionView to appear") {
            guard let app = ax.messagesApp() else { return false }
            let windows = ax.children(of: app, withRole: kAXWindowRole as String)
            guard let window = windows.first else { return false }
            return findElementByIdentifier("TranscriptCollectionView", in: window) != nil
        }
    }

    private func runOsascript(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice

            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: AppleScriptError.executionFailed(
                        status: process.terminationStatus,
                        message: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - TapbackType

public enum TapbackType: String, Sendable, Codable, CaseIterable {
    case love
    case like
    case dislike
    case laugh
    case emphasis
    case question

    /// The custom AX action name exposed on CKBalloonTextView elements.
    /// Format: "Name:<label>\nTarget:0x0\nSelector:(null)"
    public var customActionName: String {
        let label: String
        switch self {
        case .love: label = "Heart"
        case .like: label = "Thumbs up"
        case .dislike: label = "Thumbs down"
        case .laugh: label = "Ha ha!"
        case .emphasis: label = "Exclamation mark"
        case .question: label = "Question mark"
        }
        return "Name:\(label)\nTarget:0x0\nSelector:(null)"
    }
}
