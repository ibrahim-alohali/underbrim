//
//  AXElement.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Reading Accessibility attributes, for the notification reader (the helper),
//  the menu bar reader, leaving a Discord call, Quick Launch and answering the
//  Claude app's questions (the app).
//

import ApplicationServices

extension AXUIElement {
    subscript(attribute: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ attribute: String) -> String? {
        self[attribute] as? String
    }

    var exists: Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    func set(_ attribute: String, _ on: Bool) {
        AXUIElementSetAttributeValue(self, attribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// The elements an attribute lists (children, windows); none when it lists none.
    func elements(_ attribute: String) -> [AXUIElement] { (self[attribute] as? [AXUIElement]) ?? [] }

    var childElements: [AXUIElement] { elements(kAXChildrenAttribute) }

    /// The element it sits in, when that is an element.
    var parent: AXUIElement? {
        guard let value = self[kAXParentAttribute], CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The first element, breadth first, that passes `test`, looking at no more
    /// than 6000 of them: an app's tree can be very large.
    func first(where test: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [self], index = 0
        while index < queue.count, index < 6000 {
            let element = queue[index]
            index += 1
            if test(element) { return element }
            queue += element.childElements
        }
        return nil
    }

    func setPoint(_ attribute: String, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    func point(_ attribute: String) -> CGPoint? {
        guard let value = self[attribute],
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    /// Where it is on screen, top-left origin; nil unless it gives both its position and its size.
    var knownFrame: CGRect? {
        guard let origin = point(kAXPositionAttribute), let value = self[kAXSizeAttribute],
              CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Where it is on screen, top-left origin; zero when it doesn't say.
    var frame: CGRect {
        var size = CGSize.zero
        if let value = self[kAXSizeAttribute], CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: point(kAXPositionAttribute) ?? .zero, size: size)
    }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(self, &pid)
        return pid
    }
}
