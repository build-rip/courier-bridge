import AppKit
import ApplicationServices
import Foundation

/// Helper for interacting with macOS Accessibility APIs (AXUIElement).
public struct AccessibilityHelper: Sendable {
    public init() {}

    /// Check if the process has accessibility permissions.
    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Find the Messages.app AXUIElement by looking up its PID.
    /// Returns nil if Messages is not running.
    public func messagesApp() -> AXUIElement? {
        let apps = NSWorkspace.shared.runningApplications
        guard let messages = apps.first(where: { $0.bundleIdentifier == "com.apple.MobileSMS" }) else {
            return nil
        }
        return AXUIElementCreateApplication(messages.processIdentifier)
    }

    /// Get the children of an AX element, optionally filtered by role.
    public func children(of element: AXUIElement, withRole role: String? = nil) -> [AXUIElement] {
        guard let allChildren: [AXUIElement] = attribute(kAXChildrenAttribute, of: element) else {
            return []
        }
        guard let role else { return allChildren }
        return allChildren.filter { child in
            let childRole: String? = attribute(kAXRoleAttribute, of: child)
            return childRole == role
        }
    }

    /// Read an AX attribute value from an element.
    public func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success, let value else { return nil }
        return (value as? T)
    }

    /// Read a string attribute from an element.
    public func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as String?
    }

    /// Read the position of an element.
    public func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// Read the size of an element.
    public func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Recursively search for all elements matching a given role.
    public func findElements(in element: AXUIElement, role: String) -> [AXUIElement] {
        var results: [AXUIElement] = []
        let elementRole: String? = attribute(kAXRoleAttribute, of: element)
        if elementRole == role {
            results.append(element)
        }
        for child in children(of: element) {
            results.append(contentsOf: findElements(in: child, role: role))
        }
        return results
    }

    /// Recursively search for the first element matching a role and containing specific text.
    public func findElement(
        in element: AXUIElement,
        role: String,
        withValue value: String
    ) -> AXUIElement? {
        let elementRole: String? = attribute(kAXRoleAttribute, of: element)
        if elementRole == role {
            let elementValue: String? = attribute(kAXValueAttribute, of: element)
            if elementValue == value {
                return element
            }
        }
        for child in children(of: element) {
            if let found = findElement(in: child, role: role, withValue: value) {
                return found
            }
        }
        return nil
    }

    /// Get all action names for an AX element.
    public func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String]) ?? []
    }

    /// Set an AX attribute value on an element.
    @discardableResult
    public func setAttribute(_ name: String, value: CFTypeRef, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    /// Perform an action on an AX element (e.g. kAXPressAction, kAXShowMenuAction).
    @discardableResult
    public func performAction(_ action: String, on element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    /// Diagnostic: recursively dump the AX tree as a string.
    /// Useful for discovering the Messages.app element hierarchy.
    public func dumpTree(of element: AXUIElement, depth: Int = 0, maxDepth: Int = 8) -> String {
        guard depth < maxDepth else { return "" }

        let indent = String(repeating: "  ", count: depth)
        let role: String = attribute(kAXRoleAttribute, of: element) ?? "?"
        let subrole: String? = attribute(kAXSubroleAttribute, of: element)
        let title: String? = attribute(kAXTitleAttribute, of: element)
        let desc: String? = attribute(kAXDescriptionAttribute, of: element)
        let value: String? = stringAttribute(kAXValueAttribute, of: element)
        let identifier: String? = attribute(kAXIdentifierAttribute, of: element)

        var line = "\(indent)[\(role)]"
        if let subrole { line += " subrole=\(subrole)" }
        if let title { line += " title=\"\(title.prefix(60))\"" }
        if let desc { line += " desc=\"\(desc.prefix(60))\"" }
        if let value { line += " value=\"\(value.prefix(80))\"" }
        if let identifier { line += " id=\"\(identifier)\"" }
        line += "\n"

        for child in children(of: element) {
            line += dumpTree(of: child, depth: depth + 1, maxDepth: maxDepth)
        }
        return line
    }
}
