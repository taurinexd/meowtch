import ApplicationServices
import AppKit
import Foundation

/// Reads terminal tab titles from host apps via Accessibility — the
/// channel the original uses for sessions the user named at the terminal.
/// `dump` is parametric so the tree can be explored over the debug socket
/// without rebuilding (every rebuild invalidates the ad-hoc TCC grant).
@MainActor
enum AXTitleReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    struct Node {
        var role: String
        var title: String
        var depth: Int
        var window: String
    }

    struct Options {
        var bundleIdentifier = "com.microsoft.VSCode"
        var maxNodes = 6_000
        var maxDepth = 40
        var skipRoles: Set<String> = ["AXMenuBar"]
        /// Only walk windows whose title contains this (empty = all).
        var windowFilter = ""
        /// Only report nodes whose role contains this (empty = all).
        var roleFilter = ""
    }

    static func dump(options: Options = Options()) -> [Node] {
        guard isTrusted else { return [] }
        var nodes: [Node] = []
        var visited = 0
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleIdentifier) {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows: [AXUIElement] = array(appElement, kAXWindowsAttribute) else { continue }
            for window in windows {
                let windowTitle = string(window, kAXTitleAttribute) ?? "?"
                if !options.windowFilter.isEmpty,
                   !windowTitle.localizedCaseInsensitiveContains(options.windowFilter) { continue }
                walk(window, depth: 0, window: windowTitle, options: options,
                     nodes: &nodes, visited: &visited)
            }
        }
        return nodes
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        window: String,
        options: Options,
        nodes: inout [Node],
        visited: inout Int
    ) {
        visited += 1
        guard visited < options.maxNodes, depth < options.maxDepth else { return }

        let role = string(element, kAXRoleAttribute) ?? ""
        guard !options.skipRoles.contains(role) else { return }

        let title = string(element, kAXTitleAttribute)
            ?? string(element, kAXValueAttribute)
            ?? string(element, kAXDescriptionAttribute)
            ?? ""
        if !title.isEmpty,
           options.roleFilter.isEmpty || role.localizedCaseInsensitiveContains(options.roleFilter) {
            nodes.append(Node(role: role, title: String(title.prefix(140)), depth: depth, window: window))
        }

        guard let children: [AXUIElement] = array(element, kAXChildrenAttribute) else { return }
        for child in children {
            walk(child, depth: depth + 1, window: window, options: options,
                 nodes: &nodes, visited: &visited)
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func array(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
