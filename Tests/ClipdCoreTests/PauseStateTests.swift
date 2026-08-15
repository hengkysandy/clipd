import Testing
import Foundation
@testable import ClipdCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@Test("A fresh state is not paused")
func notPausedByDefault() {
    #expect(PauseState.running.isPaused(now: t0) == false)
    #expect(PauseState.running.remainingLabel(now: t0) == nil)
}

@Test("A timed pause is active until its deadline, then expires on its own")
func timedPauseExpires() {
    let state = PauseState.paused(.fifteenMinutes, from: t0)
    #expect(state.isPaused(now: t0) == true)
    #expect(state.isPaused(now: t0.addingTimeInterval(14 * 60)) == true)
    // Exactly at the deadline it is no longer paused. No timer needed, so a
    // missed timer cannot leave the app silently paused forever.
    #expect(state.isPaused(now: t0.addingTimeInterval(15 * 60)) == false)
    #expect(state.isPaused(now: t0.addingTimeInterval(60 * 60)) == false)
}

@Test("An hour pause lasts an hour")
func oneHourPause() {
    let state = PauseState.paused(.oneHour, from: t0)
    #expect(state.isPaused(now: t0.addingTimeInterval(59 * 60)) == true)
    #expect(state.isPaused(now: t0.addingTimeInterval(60 * 60)) == false)
}

@Test("An indefinite pause never expires on its own")
func indefinitePause() {
    let state = PauseState.paused(.untilResumed, from: t0)
    #expect(state.isPaused(now: t0) == true)
    #expect(state.isPaused(now: t0.addingTimeInterval(86_400 * 365)) == true)
    #expect(state.remainingLabel(now: t0) == "Paused")
}

@Test("The menu label counts down and reads sensibly near zero")
func remainingLabel() {
    let state = PauseState.paused(.fifteenMinutes, from: t0)
    #expect(state.remainingLabel(now: t0) == "Paused, 15 min left")
    #expect(state.remainingLabel(now: t0.addingTimeInterval(14 * 60)) == "Paused, 1 min left")
    // Under a minute switches to seconds rather than showing "0 min left".
    #expect(state.remainingLabel(now: t0.addingTimeInterval(14 * 60 + 30)) == "Paused, 30s left")
    // Once expired there is no label at all.
    #expect(state.remainingLabel(now: t0.addingTimeInterval(15 * 60)) == nil)
}

@Test("A clock that jumps backwards does not break the pause")
func clockGoesBackwards() {
    // Degenerate case: the deadline is in the past relative to a rewound clock.
    let state = PauseState.paused(.fifteenMinutes, from: t0)
    #expect(state.isPaused(now: t0.addingTimeInterval(-3600)) == true)
}
