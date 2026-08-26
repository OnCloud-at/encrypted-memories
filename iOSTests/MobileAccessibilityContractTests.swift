import SwiftUI
import Testing

@testable import EncryptedMemoriesMobile

@Suite struct MobileAccessibilityContractTests {
    @Test func reduceMotionDisablesViewerAnimationAndDuration() {
        #expect(MobileViewerMotionPolicy.animation(.default, reduceMotion: true) == nil)
        #expect(MobileViewerMotionPolicy.duration(0.4, reduceMotion: true) == 0)
    }

    @Test func standardMotionPreservesRequestedDuration() {
        #expect(MobileViewerMotionPolicy.animation(.default, reduceMotion: false) != nil)
        #expect(MobileViewerMotionPolicy.duration(0.4, reduceMotion: false) == 0.4)
    }
}
