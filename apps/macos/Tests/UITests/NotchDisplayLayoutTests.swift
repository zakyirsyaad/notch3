import AppKit
import Foundation
import Testing
@testable import NotchAgentCore

@Suite("Display-aware compact notch layout tests")
@MainActor
struct NotchDisplayLayoutTests {

    private let notchedScreenFrame = NSRect(x: 0, y: 0, width: 1512, height: 982)

    @Test("A physical notch requires both auxiliary top-screen areas")
    func classifiesPhysicalAndExternalDisplays() {
        let leftArea = NSRect(x: 0, y: 950, width: 660, height: 32)
        let rightArea = NSRect(x: 852, y: 950, width: 660, height: 32)

        let notched = NotchDisplayLayout(
            screenFrame: notchedScreenFrame,
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea
        )
        let missingRightArea = NotchDisplayLayout(
            screenFrame: notchedScreenFrame,
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: nil
        )

        #expect(notched.visualMode == .physicalNotch)
        #expect(notched.physicalNotchWidth == 192)
        #expect(missingRightArea.visualMode == .externalDisplay)
        #expect(missingRightArea.physicalNotchWidth == nil)
    }

    @Test("Physical notch width is padded and clamped to the compact range")
    func adaptsCollapsedWidth() {
        #expect(NotchDisplayLayout.collapsedWidth(forPhysicalNotchWidth: 160) == 220)
        #expect(NotchDisplayLayout.collapsedWidth(forPhysicalNotchWidth: 192) == 232)
        #expect(NotchDisplayLayout.collapsedWidth(forPhysicalNotchWidth: 300) == 260)
        #expect(NotchDisplayLayout.collapsedHeight == 32)
    }

    @Test("External displays use the fixed compact pill size")
    func externalDisplayUsesFixedSize() {
        let layout = NotchDisplayLayout(
            screenFrame: NSRect(x: -1728, y: 0, width: 1728, height: 1117),
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )

        #expect(layout.collapsedSize == CGSize(width: 220, height: 32))
        #expect(layout.showsProductName)
    }

    @Test("Collapsed trigger frame is centered and equals the collapsed panel frame")
    func triggerFrameMatchesCollapsedFrame() {
        let layout = NotchDisplayLayout(
            screenFrame: notchedScreenFrame,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 950, width: 660, height: 32),
            auxiliaryTopRightArea: NSRect(x: 852, y: 950, width: 660, height: 32)
        )

        #expect(layout.triggerFrame == layout.frame(for: layout.collapsedSize))
        #expect(layout.triggerFrame.midX == notchedScreenFrame.midX)
        #expect(layout.triggerFrame.maxY == notchedScreenFrame.maxY)
    }

    @Test("External title center is invariant when an actual task badge is present")
    func externalTitleCenterIsStable() {
        let frame = CGRect(x: 0, y: 0, width: 220, height: 32)
        let idleRegions = NotchHUDLayout.collapsedRegionFrames(
            in: frame,
            hasActiveTaskBadge: false
        )
        let activeRegions = NotchHUDLayout.collapsedRegionFrames(
            in: frame,
            hasActiveTaskBadge: true
        )

        #expect(idleRegions.count == 3)
        #expect(activeRegions == idleRegions)
        #expect(idleRegions[1].midX == frame.midX)
    }

    @Test("Reduce Motion removes panel and drawer translation durations")
    func reduceMotionContract() {
        #expect(NotchWindowController.animationDuration(isOpening: true, reduceMotion: false) == 0.26)
        #expect(NotchWindowController.animationDuration(isOpening: false, reduceMotion: false) == 0.18)
        #expect(NotchWindowController.animationDuration(isOpening: true, reduceMotion: true) == 0)
        #expect(NotchHUDLayout.drawerAnimationDuration(isInsertion: true, reduceMotion: false) == 0.20)
        #expect(NotchHUDLayout.drawerAnimationDuration(isInsertion: false, reduceMotion: false) == 0.12)
        #expect(NotchHUDLayout.drawerAnimationDuration(isInsertion: true, reduceMotion: true) == 0)
        #expect(NotchHUDLayout.drawerMotionOffset(reduceMotion: false) == 6)
        #expect(NotchHUDLayout.drawerMotionOffset(reduceMotion: true) == 0)
    }
}
