// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import AVFoundation

/// the intro's beats in seconds from the score's start, read by the picture; tools/intro-score.py
/// composes the score on the same beats
nonisolated enum IntroBeat {
    /// the screen fading from the desktop to the night sky, once the music has begun
    static let dawn = 0.4...6.8
    static let message = 4.8...7.8
    /// the left arm appearing, then the right: bars 8 and 9 at 109 bpm
    static let arms = [17.6, 19.8]
    /// the comet's swoosh round the A, the score's one climax
    static let reveal = 22.0
    static let title = 22.5
    /// the full-screen sky shrinking onto the browser window
    static let shrink = 26.4

    static func ramp(_ from: Double, _ to: Double, _ t: Double) -> Double {
        min(1, max(0, (t - from) / (to - from)))
    }

    static func ease(_ from: Double, _ to: Double, _ t: Double) -> Double {
        let x = ramp(from, to, t)
        return x * x * (3 - 2 * x)
    }
}

/// the intro's score, played from the bundle
@MainActor
final class IntroSound {
    static let url = Bundle.main.url(forResource: "intro-score", withExtension: "m4a")
    private let player = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }

    var isMuted = false {
        didSet { player?.setVolume(isMuted ? 0 : 1, fadeDuration: 0.25) }
    }

    /// starts the score a moment from now and returns that moment
    func start() -> Date {
        guard let player, player.prepareToPlay() else { return Date() }
        let lead = 0.06
        player.play(atTime: player.deviceCurrentTime + lead)
        return Date(timeIntervalSinceNow: lead)
    }

    func fadeOut(over seconds: Double = 0.8) {
        guard let player, player.isPlaying else { return }
        player.setVolume(0, fadeDuration: seconds)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            player.stop()
        }
    }
}
