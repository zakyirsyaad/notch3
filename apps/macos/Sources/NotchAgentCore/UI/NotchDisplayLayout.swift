import AppKit
import Foundation

/// The two visual treatments supported by the collapsed Notch3 chrome.
public enum NotchDisplayMode: Equatable, Sendable {
    case physicalNotch
    case externalDisplay

    public var isPhysicalNotch: Bool {
        self == .physicalNotch
    }

    public var showsProductName: Bool {
        self == .externalDisplay
    }
}

/// Display-derived geometry shared by the visible collapsed chrome and its
/// invisible click target. Keeping both frames in one value prevents the hit
/// area from drifting away from the rendered surface when a display changes.
public struct NotchDisplayLayout: Equatable, Sendable {
    public static let collapsedHeight: CGFloat = 32
    public static let externalCollapsedWidth: CGFloat = 220
    public static let externalCollapsedSize = CGSize(width: externalCollapsedWidth, height: collapsedHeight)
    public static let minimumCollapsedWidth: CGFloat = 220
    public static let maximumCollapsedWidth: CGFloat = 260
    public static let brandMarkSize = CGSize(width: 14, height: 11)

    public let screenFrame: NSRect
    public let visualMode: NotchDisplayMode
    public let physicalNotchWidth: CGFloat?
    public let collapsedSize: CGSize
    public let triggerFrame: NSRect

    public var showsProductName: Bool {
        visualMode.showsProductName
    }

    public init(
        screenFrame: NSRect,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) {
        self.screenFrame = screenFrame

        let notchWidth = Self.physicalNotchWidth(
            in: screenFrame,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )
        self.physicalNotchWidth = notchWidth
        self.visualMode = notchWidth == nil ? .externalDisplay : .physicalNotch

        let width = Self.collapsedWidth(forPhysicalNotchWidth: notchWidth)
        self.collapsedSize = CGSize(width: width, height: Self.collapsedHeight)
        self.triggerFrame = Self.frame(
            on: screenFrame,
            contentSize: self.collapsedSize
        )
    }

    public init(screen: NSScreen) {
        self.init(
            screenFrame: screen.frame,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    /// A deterministic fallback used only when AppKit has not exposed a
    /// screen yet during process startup.
    public static let fallback = NotchDisplayLayout(
        screenFrame: NSRect(x: 100, y: 100, width: 220, height: 32),
        auxiliaryTopLeftArea: nil,
        auxiliaryTopRightArea: nil
    )

    public static func collapsedWidth(forPhysicalNotchWidth physicalNotchWidth: CGFloat?) -> CGFloat {
        guard let physicalNotchWidth,
              physicalNotchWidth.isFinite,
              physicalNotchWidth > 0 else {
            return externalCollapsedWidth
        }

        return min(
            max(physicalNotchWidth + 40, minimumCollapsedWidth),
            maximumCollapsedWidth
        )
    }

    public static func physicalNotchWidth(
        in screenFrame: NSRect,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) -> CGFloat? {
        guard let auxiliaryTopLeftArea,
              let auxiliaryTopRightArea,
              !auxiliaryTopLeftArea.isEmpty,
              !auxiliaryTopRightArea.isEmpty else {
            return nil
        }

        let gap = auxiliaryTopRightArea.minX - auxiliaryTopLeftArea.maxX
        guard gap > 0, gap < screenFrame.width else { return nil }
        return gap
    }

    public func frame(for contentSize: CGSize) -> NSRect {
        Self.frame(on: screenFrame, contentSize: contentSize)
    }

    private static func frame(on screenFrame: NSRect, contentSize: CGSize) -> NSRect {
        NSRect(
            x: screenFrame.minX + (screenFrame.width - contentSize.width) / 2,
            y: screenFrame.maxY - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }
}
