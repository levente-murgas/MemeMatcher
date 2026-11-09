import Foundation
import UIKit
import Shared
import os.log

/// M3/M3.5: ranks the bundled memes against the user's live capture.
///
/// Matching is driven by a list of `ChannelConfig`s rather than hardcoded to
/// one signal. Each channel is scored independently by cosine similarity over
/// name-aligned vectors, then combined according to its role:
///
///   * `.primary` — decides whether a meme is matchable at all, and forms the
///     base score. A meme lacking every primary channel is not shown.
///   * `.bonus`   — can only ever *add*, and only when the channel is present
///     on both the live capture and that meme. Never penalizes.
///
/// Adding a future channel is a config entry plus a live vector, not a rewrite.
final class MatchEngine: ObservableObject {

    struct Match: Identifiable {
        let file: String
        let score: Float
        /// Per-channel similarity behind `score`, for UI and tuning.
        let channelScores: [String: Float]
        var id: String { file }

        /// True when a bonus channel actually contributed to this match.
        func hasBonus(from channel: String) -> Bool {
            (channelScores[channel] ?? 0) > 0
        }
    }

    enum Role { case primary, bonus }

    struct ChannelConfig {
        let id: String
        let role: Role
        let weight: Float
        /// Component names to drop before comparing (by name, not index).
        let excludes: (String) -> Bool
    }

    /// Channel configuration — the single place matching behaviour is tuned.
    ///
    /// `faceBlendshapes`: gaze (`eyeLook*`) and blink (`eyeBlink*`) describe
    /// where the eyeballs point, not expression; pack analysis showed they let
    /// a resting face match "looking down" memes and made side-eye memes
    /// unreachable. `_neutral` is dead weight. 41 of 52 coefficients remain.
    ///
    /// `handLandmarks`: no exclusions — every component is shape information,
    /// and pack analysis showed distinct poses score far apart (≈ -0.57), so
    /// the dynamic-range problem that motivated the face exclusions is absent.
    private static let channels: [ChannelConfig] = [
        ChannelConfig(
            id: FeatureChannel.faceBlendshapes,
            role: .primary,
            weight: 1.0,
            excludes: { name in
                name == "_neutral" || name.hasPrefix("eyeLook") || name.hasPrefix("eyeBlink")
            }
        ),
        ChannelConfig(
            id: FeatureChannel.handLandmarks,
            role: .bonus,
            weight: 0.3,
            excludes: { _ in false }
        ),
    ]

    /// Minimum L2 norm of the filtered live *primary* vector to produce matches
    /// at all. Below this the face is essentially at rest and rankings would be
    /// noise — the plan's "no clear expression" gate.
    private static let minLiveNorm: Float = 0.25

    /// How much better a challenger must score than the weakest current member
    /// before it swaps in. Absorbs frame-to-frame jitter so the strip stays
    /// tappable while an expression is held.
    private static let hysteresisMargin: Float = 0.06

    private static let log = Logger(subsystem: "com.leventemurgas.MemeMatcher", category: "matching")

    /// Per-channel prepared data: kept component names, and each meme's vector
    /// already filtered to those components.
    private struct PreparedChannel {
        let config: ChannelConfig
        let names: [String]
        let vectorsByFile: [String: [Float]]
    }
    private var prepared: [PreparedChannel] = []

    /// The memes currently on screen, in fixed display positions. A position
    /// only changes content when a non-member beats it — the array order is
    /// never re-sorted, which is what keeps the strip from shuffling.
    private var stableTopFiles: [String] = []

    // MARK: - Loading

    /// Load the bundled manifest once at startup.
    func load() {
        guard prepared.isEmpty else { return }
        // The pack may land in the bundle root or a MemePack/ subdirectory
        // depending on how the resources were copied — check both.
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json")
                ?? Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "MemePack")
        else {
            Self.log.error("MATCH manifest.json not found in bundle")
            return
        }

        let pack: MemePack
        do {
            pack = try JSONDecoder().decode(MemePack.self, from: Data(contentsOf: url))
        } catch {
            Self.log.error("MATCH manifest decode failed: \(error.localizedDescription)")
            return
        }

        prepared = Self.channels.compactMap { config in
            guard let schema = pack.featureSchemas[config.id] else {
                Self.log.error("MATCH channel '\(config.id)' missing from manifest, skipped")
                return nil
            }
            let keptIndices = schema.names.indices.filter { !config.excludes(schema.names[$0]) }
            var vectorsByFile: [String: [Float]] = [:]
            for meme in pack.memes {
                guard let full = meme.features[config.id], full.count == schema.names.count else { continue }
                vectorsByFile[meme.file] = keptIndices.map { full[$0] }
            }
            return PreparedChannel(config: config,
                                   names: keptIndices.map { schema.names[$0] },
                                   vectorsByFile: vectorsByFile)
        }

        for channel in prepared {
            Self.log.error("MATCH channel '\(channel.config.id)': \(channel.vectorsByFile.count) memes, \(channel.names.count) components")
        }
        Self.log.error("MATCH pack loaded: \(pack.memes.count) memes total")
    }

    // MARK: - Matching

    /// Top matches, held stable in fixed positions across calls.
    ///
    /// - Parameters:
    ///   - named: live vectors keyed by channel id, each as name→value pairs.
    ///     Alignment happens by *name*, so caller ordering is irrelevant.
    ///     A channel absent from this dictionary simply doesn't contribute.
    func stableTopMatches(named liveByChannel: [String: [Blendshape]],
                          count: Int = 3) -> [Match] {
        guard !prepared.isEmpty else { return [] }

        // Align each live channel to its prepared component order.
        var liveVectors: [String: [Float]] = [:]
        for channel in prepared {
            guard let live = liveByChannel[channel.config.id], !live.isEmpty else { continue }
            let byName = Dictionary(live.map { ($0.name, $0.score) }, uniquingKeysWith: { first, _ in first })
            liveVectors[channel.config.id] = channel.names.map { byName[$0] ?? 0 }
        }

        // Rest gate: at least one primary channel must carry real signal.
        let primaries = prepared.filter { $0.config.role == .primary }
        let hasLiveSignal = primaries.contains { channel in
            guard let vector = liveVectors[channel.config.id] else { return false }
            return vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot() >= Self.minLiveNorm
        }
        guard hasLiveSignal else {
            stableTopFiles = []
            return []
        }

        // Score every meme that has at least one primary vector.
        var scoreByFile: [String: Float] = [:]
        var breakdownByFile: [String: [String: Float]] = [:]

        let matchableFiles = Set(primaries.flatMap { $0.vectorsByFile.keys })
        for file in matchableFiles {
            var total: Float = 0
            var breakdown: [String: Float] = [:]

            for channel in prepared {
                guard let live = liveVectors[channel.config.id],
                      let memeVector = channel.vectorsByFile[file] else { continue }
                switch channel.config.role {
                case .primary:
                    let similarity = VectorMath.cosineSimilarity(live, memeVector)
                    total += channel.config.weight * similarity
                    breakdown[channel.config.id] = similarity
                case .bonus:
                    // Clamped: a bonus channel must never subtract.
                    let similarity = VectorMath.positiveSimilarity(live, memeVector)
                    total += channel.config.weight * similarity
                    breakdown[channel.config.id] = similarity
                }
            }
            scoreByFile[file] = total
            breakdownByFile[file] = breakdown
        }
        guard !scoreByFile.isEmpty else { return [] }

        // Hysteresis: hold positions; swap in at most one challenger per call.
        if stableTopFiles.isEmpty {
            stableTopFiles = scoreByFile.sorted { $0.value > $1.value }.prefix(count).map(\.key)
        } else {
            stableTopFiles = stableTopFiles.filter { scoreByFile[$0] != nil }
            if let weakest = stableTopFiles
                .map({ (file: $0, score: scoreByFile[$0] ?? -1) })
                .min(by: { $0.score < $1.score }) {
                let challenger = scoreByFile
                    .filter { !stableTopFiles.contains($0.key) }
                    .max { $0.value < $1.value }
                if let challenger, challenger.value > weakest.score + Self.hysteresisMargin,
                   let weakestIndex = stableTopFiles.firstIndex(of: weakest.file) {
                    stableTopFiles[weakestIndex] = challenger.key
                }
            }
            // Backfill if the pack got smaller than `count`.
            if stableTopFiles.count < count {
                for candidate in scoreByFile.sorted(by: { $0.value > $1.value }).map(\.key)
                where !stableTopFiles.contains(candidate) && stableTopFiles.count < count {
                    stableTopFiles.append(candidate)
                }
            }
        }

        return stableTopFiles.map {
            Match(file: $0, score: scoreByFile[$0] ?? 0, channelScores: breakdownByFile[$0] ?? [:])
        }
    }

    /// Load a meme's image from the bundle (root or MemePack/ subdirectory).
    static func image(named file: String) -> UIImage? {
        let url = Bundle.main.url(forResource: file, withExtension: nil)
            ?? Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "MemePack")
        guard let url else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
