//
//  VirtualPipaController.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/11/13.
//
//  Gesture-driven "air Pipa" controller for the Swift Student Challenge.
//
//  It subscribes to the camera via the existing CameraManager, runs the
//  existing HandPoseExtractor on each frame, and turns the two hands into
//  musical intent:
//    - left hand  -> (string, fret) selection  -> the pitch
//    - right hand -> pluck / sweep, gated to that one selected string
//  With no fret held, the left hand releases after a short delay and the
//  plucked string sounds open, the way a real Pipa behaves when the finger
//  comes off. The pitch never follows the right hand: a right-hand flick only
//  decides *whether* and *which string*, never the fret. That flick is
//  one-directional, like the instrument: the fingers 弹 across the strings from
//  screen right to left, the thumb 挑 from left to right, and the way back is
//  silent. This gate lives here in the controller, not on the UI.
//  VirtualPipaEngine renders ElectricPipa's physical-modeling synth and feeds
//  the buffers into the same onBufferReceived closure the microphone would use,
//  so the tuner, classifier and games react with no real instrument, no mic
//  and no network. Camera confirmed available in the SSC playground.

import Foundation
import Vision
import AVFoundation
import Combine
import UIKit

/// 虚拟琵琶上的 (弦, 品) 位置，用于 HUD 显示与触发发声。
struct PipaSelection: Equatable {
    let string: Int
    let fret: Int
}

/// Normalized geometry of the virtual neck, shared by the gesture controller
/// and the Canvas that draws it. Screen space: origin top-left, x and y in
/// 0...1, y growing downward. Keeping these numbers in one place is what stops
/// the hands' sensing area drifting away from the four drawn strings.
enum VirtualPipaGeometry {
    /// `neckW = width * 0.46`, `neckH = height * 0.66`, centred on screen.
    static let neck = CGRect(x: 0.27, y: 0.17, width: 0.46, height: 0.66)
    static let stringCount = 4
    /// 7 frets + open string = 8 selectable positions per string.
    static let positionCount = 8
    static let fretCount = positionCount - 1
}

@MainActor
class VirtualPipaController: ObservableObject {

    // Reuse the existing camera pipeline (front camera, mirrored, 90° rotation).
    let camera = CameraManager()

    private let extractor = HandPoseExtractor()

    // MARK: - Published UI state

    /// Hands detected in the latest frame (for the on-screen skeleton overlay).
    @Published var hands: [DetectedHand] = []
    /// Current left-hand (string, fret) selection, or nil when left hand absent.
    @Published var selection: PipaSelection?
    /// Human-readable note label for the HUD, e.g. "A4".
    @Published var noteLabel: String = ""
    @Published var isRunning = false
    /// Set when VirtualPipaEngine fails to start, so the view can explain it.
    @Published var engineError: String?

    // MARK: - Tuning knobs (verify live; see notes below)

    /// Map screen column -> string index. Calibrated against the user's camera:
    /// `false` matches the drawn neck (moving right picks the next string).
    private let stringOrderReversed = false
    /// Flip the fret direction ONCE if the marker still runs against the hand.
    /// The old `invertY` flipped y and then subtracted from fretCount again, so
    /// the two flips cancelled out and toggling it appeared to do nothing.
    private let invertFret = false
    /// 7 frets + open string = 8 selectable positions per string.
    private let fretCount = VirtualPipaGeometry.fretCount

    /// Normalized fingertip travel per frame, in screen widths, that counts as a
    /// pluck. Per finger, because the lever behind each one is not the same: the
    /// index swings from the knuckle while the thumb rolls from the base of the
    /// hand, so for one stroke its tip covers roughly half the ground. Measured
    /// by the index's ruler a 挑 came in at about three fifths of it, and that
    /// single shared threshold is why the thumb never sounded while 弹 did.
    private static let pluckTravelThreshold: [String: CGFloat] = [
        "thumb":  0.030,
        "index":  0.050,
        "middle": 0.050,
        "ring":   0.050,
        "little": 0.050
    ]
    /// A stroke that crosses a drawn string is a pluck by definition — that is
    /// what a pluck is, the fingertip passing through the string. It still has
    /// to be travelling across the neck rather than along it, or a hand sliding
    /// up the strings would rake them; this is the loosest angle allowed through.
    private static let crossingAcrossRatio: CGFloat = 0.35
    /// When the stroke is too short, or too square-on to the camera, to cross a
    /// line on screen, the nearest string is credited instead — but only for a
    /// full-size stroke that is clearly horizontal, so a fingertip resting on
    /// the neck cannot fire on its own jitter.
    private static let guessTravelThreshold: CGFloat = 0.05
    private static let guessAcrossRatio: CGFloat = 0.8
    /// How far a flick must travel to reach full velocity, in screen widths.
    /// Between that finger's threshold and this the velocity rises linearly.
    private let fullVelocityTravel: CGFloat = 0.18
    /// Velocity range a pluck is mapped onto: the softest flick that still
    /// registers, and the hardest. The engine scales gain linearly with velocity,
    /// so this is dynamics in loudness — the fitted model was measured at a single
    /// force and has no brighter-timbre-with-force behaviour to drive.
    private let pluckVelocityRange: ClosedRange<Double> = 0.45...1.0
    /// Minimum gap between two plucks *of the same finger*. Per-finger, so a fast
    /// wheel (thumb→index→middle→ring) is not throttled by the previous finger.
    private let pluckDebounce: TimeInterval = 0.10
    /// Wrist travel per frame above which the arm is moving the hand and no
    /// fingertip flick counts. A pluck is a finger action; a sweep is an arm
    /// action, and the wrist is what tells them apart. Below the sweep threshold
    /// (`sweepDxThreshold`) an arm can still be carrying the hand across the
    /// neck, which is what used to fire notes while waving.
    private let armMotionThreshold: CGFloat = 0.12
    /// Normalized horizontal wrist travel that counts as a sweep across strings.
    private let sweepDxThreshold: CGFloat = 0.35
    private let sweepDebounce: TimeInterval = 0.40
    /// How long the neck may go unpressed before the selection is released and
    /// plucks return to the open string. Long enough to ride out a dropped hand
    /// detection or a fingertip skimming the neck edge, short enough that
    /// lifting the left hand still feels like coming off the string.
    ///
    /// Half a second is roughly the gap between phrases: a hand that leaves the
    /// neck and comes back inside that window keeps its note, so a reposition
    /// does not flicker through the open string; a hand that stays away is
    /// clearly not stopping anything and the string goes open.
    private let selectionReleaseDelay: TimeInterval = 0.5

    // Open-string base frequencies per `string` index passed to
    // VirtualPipaEngine.pluck(string:fret:). Matches PipaTuning.openStringMIDI
    // ([45, 50, 52, 57]): index 0 is the thick Chan string, index 3 the thin
    // Zi string. Standard 正调 A-d-e-a = A2 / d3 / e3 / a3, the register the
    // instrument actually sounds in and the one the fitted model was measured at.
    private let openFreqs: [Double] = [110.0, 146.83, 164.81, 220.0]

    // MARK: - Frame-to-frame gesture memory

    /// One joint of the right hand, remembered with which joint it was so a
    /// finger that changes joints between frames is never read as a stroke.
    private struct FingerSample {
        let point: CGPoint
        let joint: String
    }

    /// Previous position per **finger** (not per joint), so a finger that has to
    /// be read through a joint further back this frame keeps one continuous
    /// history instead of jumping between points.
    private var rightFingerPrev: [String: FingerSample] = [:]
    /// Last pluck time per finger — each finger has its own debounce so a fast
    /// wheel isn't throttled by the previous finger's pluck.
    private var lastPluckByFinger: [String: Date] = [:]
    private var rightWristPrev: CGPoint?
    private var lastSweep = Date.distantPast
    /// Last frame a left fingertip was mapped onto the neck. Drives the release
    /// back to the open string when the hand stops pressing.
    private var lastSelectionSeen = Date.distantPast

    /// The pluckable fingers and the joints that may stand in for each tip, in
    /// order of preference. All five are tracked, so every finger — the thumb
    /// included, which the old index-only logic ignored — makes sound.
    ///
    /// The fallback matters more for the thumb than for the others. Vision does
    /// not drop a joint it cannot see: it returns it at confidence 0 at a
    /// guessed position. With the thumb tucked alongside the index, the way it
    /// sits in 弹挑, its tip is the least visible point on the hand, so it was
    /// read as a fabricated dot that barely moved and no stroke ever cleared the
    /// bar. The joints behind the tip are seen far more reliably and move with
    /// it, so one of them is used whenever the tip is a guess.
    private let pluckJoints: [(finger: String, joints: [String])] = [
        ("thumb",  ["thumbTip", "thumbIP", "thumbMP"]),
        ("index",  ["indexTip", "indexDIP"]),
        ("middle", ["middleTip", "middleDIP"]),
        ("ring",   ["ringTip", "ringDIP"]),
        ("little", ["littleTip", "littleDIP"])
    ]
    /// Confidence below which a joint is treated as a guess rather than a
    /// reading — the same cut-off the rest of the project uses.
    private let pluckConfidenceFloor = 0.3

    /// Which way each finger has to be travelling to make a sound.
    ///
    /// A pluck only counts one way round. The four fingers 弹 outward, across the
    /// strings from screen right to left; the thumb 挑 the other way, from left
    /// to right. The opposite motion is either the return half of the stroke or
    /// the hand curling in behind the string, and neither plucks anything — left
    /// in, it sounded the string twice, and a hand tucked inward played notes it
    /// never struck.
    ///
    /// These are screen directions, and the screen shows the camera mirrored, so
    /// they are the directions the player sees — the same x the strings are drawn
    /// on, not the ones the sensor physically saw.
    private static let pluckDirection: [String: CGFloat] = [
        "thumb":  1,
        "index": -1,
        "middle": -1,
        "ring":   -1,
        "little": -1
    ]
    /// Travel *along the plucking direction* below which its sign is noise, in
    /// screen widths. A stroke more vertical than this has no direction to speak
    /// of and is rejected by the angle test anyway.
    private static let pluckDirectionFloor: CGFloat = 0.008

    // MARK: - Diagnostics

    /// Live one-line readout of what the right hand is doing: per-finger travel
    /// this frame in thousandths of a screen width, then the current selection.
    /// Off by default; flip it to `true` to tune the pluck gates on a device
    /// where the only instrument is a camera.
    static let showPluckDiagnostics = false
    @Published var pluckDiagnostics = ""

    // MARK: - Lifecycle

    init() {
        // Mirror the engine's startup error into the controller so the view can
        // show it without reaching into the engine directly. `assign(to:)` is
        // actor-safe and keeps the published value in sync on the main actor.
        // `assign(to: &$engineError)` is the @Published inout overload: it feeds
        // the engine's error straight into our published property and returns
        // Void (the subscription is owned by the published property itself), so
        // there is nothing to store in `cancellables`.
        VirtualPipaEngine.shared.$startupError
            .receive(on: DispatchQueue.main)
            .assign(to: &$engineError)
    }

    func start() {
        engineError = nil
        camera.onFrameCapture = { [weak self] buffer in
            Task { [weak self] in
                guard let self else { return }
                if let detected = try? await self.extractor.extractHands(from: buffer) {
                    self.consume(detected)
                }
            }
        }
        camera.configureSession()
        camera.startSession()
        // Kick off the engine start on a background thread (the engine owns the
        // async start). Any failure surfaces through `engineError` via the
        // subscription above, so the initial `false` is not an error — don't
        // treat it as one.
        VirtualPipaEngine.shared.ensureStarted()
        isRunning = true
    }

    func stop() {
        camera.stopSession()
        camera.onFrameCapture = nil
        VirtualPipaEngine.shared.stop()
        isRunning = false
        hands = []
        selection = nil
        noteLabel = ""
        rightWristPrev = nil
        rightFingerPrev.removeAll()
        lastPluckByFinger.removeAll()
        lastSelectionSeen = Date.distantPast
    }

    /// Re-attempt only the audio engine after a recoverable failure (e.g. another
    /// app briefly held the audio session). The camera is already running, so we
    /// just re-arm the synth and surface any new error.
    func retryEngine() {
        engineError = nil
        // `startState` is `.failed`, so ensureStarted() re-arms the background
        // start and the error (if any) flows back through `engineError`.
        VirtualPipaEngine.shared.ensureStarted()
    }

    // MARK: - Per-frame processing (main actor)

    private func consume(_ detected: [DetectedHand]) {
        hands = detected
        let now = Date()

        // Left hand owns the whole pitch: both which string and which fret,
        // read at the index fingertip because that is the point that stops the
        // string. The right hand never changes it.
        //
        // When no fingertip is on the neck, nothing is being stopped, so the
        // selection is released and a pluck sounds the open string — the same
        // thing a real Pipa does when the finger comes off. The release is
        // delayed rather than instant: Vision drops the hand for a frame or two
        // now and then, and the fingertip itself skims the edge of the neck
        // while the hand travels. Without the delay the note would flap between
        // a fret and the open string on every one of those frames. Short gaps
        // therefore keep the last note, long absences go back to open.
        if let left = detected.first(where: { $0.chirality == .left }),
           let mapped = Self.mapSelection(left.keypoints,
                                          stringOrderReversed: stringOrderReversed,
                                          invertFret: invertFret,
                                          fretCount: fretCount) {
            selection = mapped
            lastSelectionSeen = now
            noteLabel = Self.noteName(string: mapped.string, fret: mapped.fret,
                                      openFreqs: openFreqs)
        } else if selection != nil,
                  now.timeIntervalSince(lastSelectionSeen) > selectionReleaseDelay {
            selection = nil
            noteLabel = ""
        }

        // Right hand triggers sound. Any of the five fingers fires a pluck, so
        // alternating fingers in 轮指 (thumb/index/middle/ring) sounds like a
        // continuous wheel. Each finger keeps its own history and debounce so
        // one finger doesn't gate the next.
        guard let right = detected.first(where: { $0.chirality == .right }) else {
            rightWristPrev = nil
            rightFingerPrev.removeAll()
            lastPluckByFinger.removeAll()
            return
        }

        func located(_ name: String) -> CGPoint? {
            right.keypoints.first { $0.name == name }?.location
        }

        // Where each finger is read this frame. Built once and used for both the
        // stroke test and the history update, so the two can never disagree
        // about which joint a finger was read through.
        var samples: [String: FingerSample] = [:]
        for (finger, joints) in pluckJoints {
            if let sample = Self.fingerSample(joints, in: right,
                                             confidenceFloor: pluckConfidenceFloor) {
                samples[finger] = sample
            }
        }

        let wrist = located("wrist")

        // Strum: a fast horizontal wrist move. Consume the sweep either way so
        // it is never misread as a pluck. With a fret held it only sounds when
        // the sweep starts on the string the left hand selected; with no fret
        // held the whole neck is four open strings, so any sweep is a sweep.
        if let w = wrist, let pw = rightWristPrev,
           abs(w.x - pw.x) > sweepDxThreshold,
           now.timeIntervalSince(lastSweep) > sweepDebounce {
            let startsOn = Self.stringForX(pw.x, reversed: stringOrderReversed)
            if selection == nil || startsOn == selection?.string {
                VirtualPipaEngine.shared.strum(ascending: w.x - pw.x > 0, velocity: 0.78)
            }
            lastSweep = now
            rightWristPrev = w
            // Snapshot the fingers so the wrist sweep isn't misread as a pluck.
            rightFingerPrev = samples
            return
        }

        // Pluck: the finger travelling furthest this frame fires once, if its
        // stroke looks like a pluck and not like the hand moving about.
        //   · it is going the plucking way — fingers right to left, thumb left
        //     to right; the way back is not a pluck and never sounds
        //   · it covers enough ground for *that finger* — the thumb rolls from
        //     the base of the hand and needs less than the index does
        //   · it crosses a string, or (when the stroke points at the camera and
        //     projects as a stub) it is at least a full, clearly horizontal one
        //   · the arm is not carrying the hand at the time — moving the wrist
        //     fast makes fingertips travel too, and that is a sweep, not a pluck
        //   · how far it travels sets the velocity, so a gentle stroke is quiet
        //
        // Gate: with a fret held the pluck only sounds on the string the left
        // hand selected, and the note is that fret; with no fret held, the
        // plucked string sounds open. The right hand picks the string, never the
        // pitch.
        //
        // Vision normalises x by the frame width and y by its height, so both
        // axes are brought onto the width's ruler before anything is compared.
        let yScale = right.imageSize.width > 0 && right.imageSize.height > 0
            ? right.imageSize.height / right.imageSize.width
            : 1
        let armMoving = (wrist.flatMap { w in
            rightWristPrev.map { hypot(w.x - $0.x, (w.y - $0.y) * yScale) }
        } ?? 0) > armMotionThreshold

        struct Stroke {
            let finger: String
            let from: CGPoint
            let to: CGPoint
            let travel: CGFloat
            let across: CGFloat
            /// Horizontal travel in the finger's own plucking direction.
            let along: CGFloat
        }

        var strokes: [Stroke] = []
        for (finger, _) in pluckJoints {
            guard let sample = samples[finger] else { continue }
            // A finger read through a different joint than last frame has no
            // honest delta: the tip and the joint behind it sit a couple of
            // centimetres apart, and that gap would read as a stroke. Its
            // history is reset below instead.
            guard let prev = rightFingerPrev[finger], prev.joint == sample.joint else { continue }
            let dx = sample.point.x - prev.point.x
            let dy = (sample.point.y - prev.point.y) * yScale
            let travel = hypot(dx, dy)
            let across = abs(dy) > 0 ? abs(dx) / abs(dy) : .greatestFiniteMagnitude
            let along = dx * (Self.pluckDirection[finger] ?? 0)
            strokes.append(Stroke(finger: finger, from: prev.point, to: sample.point,
                                  travel: travel, across: across, along: along))
        }

        for stroke in strokes.sorted(by: { $0.travel > $1.travel }) {
            let threshold = Self.pluckTravelThreshold[stroke.finger] ?? Self.guessTravelThreshold
            guard !armMoving,
                  stroke.along > Self.pluckDirectionFloor,
                  stroke.travel > threshold,
                  now.timeIntervalSince(lastPluckByFinger[stroke.finger] ?? Date.distantPast) > pluckDebounce,
                  let string = Self.attributedPluck(fromX: stroke.from.x,
                                                    toX: stroke.to.x,
                                                    travel: stroke.travel,
                                                    across: stroke.across,
                                                    reversed: stringOrderReversed)
            else { continue }

            let velocity = pluckVelocity(for: stroke.travel, threshold: threshold)
            if let sel = selection {
                guard string == sel.string else { continue }
                VirtualPipaEngine.shared.pluck(string: sel.string, fret: sel.fret,
                                               velocity: velocity, position: 0.5)
            } else {
                VirtualPipaEngine.shared.pluck(string: string, fret: 0,
                                               velocity: velocity, position: 0.5)
            }
            lastPluckByFinger[stroke.finger] = now
            break
        }

        if Self.showPluckDiagnostics {
            let readout = strokes
                .sorted { $0.travel > $1.travel }
                .map { stroke in
                    let mark = stroke.along > 0 ? "+" : "-"
                    return "\(stroke.finger.prefix(1).uppercased())\(mark)\(Int((stroke.travel * 1000).rounded()))"
                }
                .joined(separator: " ")
            let held = selection.map { "\($0.string)/\($0.fret)" } ?? "-"
            pluckDiagnostics = "\(readout) | \(held)"
        }

        // Always advance every finger's history so each delta is frame-to-frame.
        // A finger that is missing this frame loses its history instead of
        // keeping a stale position: when it comes back, the delta would
        // otherwise be measured across the gap and pass the flick threshold on
        // its own, sounding a note the player never played.
        rightFingerPrev = samples

        rightWristPrev = wrist
    }

    // MARK: - Mapping helpers

    /// The joint that stands for a finger's tip this frame: the first one in the
    /// chain Vision is actually confident about.
    ///
    /// A joint Vision cannot see is still reported, at confidence 0 and a
    /// guessed position — a point that does not move with the finger. Skipping
    /// those is the difference between "the thumb never plucks" and the thumb
    /// working: its tip is the least visible point on a hand playing 弹挑.
    private static func fingerSample(_ joints: [String],
                                     in hand: DetectedHand,
                                     confidenceFloor: Double) -> FingerSample? {
        for joint in joints {
            guard let kp = hand.keypoints.first(where: { $0.name == joint }),
                  kp.confidence > confidenceFloor else { continue }
            return FingerSample(point: kp.location, joint: joint)
        }
        return nil
    }

    /// Which string a stroke plucked, from where the fingertip went.
    ///
    /// A pluck is the fingertip passing *through* the string, so the note is the
    /// line the stroke crossed — not the band the fingertip happened to end up
    /// in. Reading the end position was wrong in both directions: a 挑 finishes
    /// barely past the string it plucked and rounds into the next band, which
    /// dropped the note on a string mismatch, and a stroke that finished outside
    /// the neck produced no string at all and was silent. Either way the thumb
    /// was the finger that suffered.
    ///
    /// When no line is crossed on screen — the stroke is short, or it points at
    /// the camera and projects as a stub — the nearest string to the middle of
    /// the stroke is used instead, but only for a stroke that passes the general
    /// size and angle tests. `nil` means nothing was plucked.
    ///
    /// The caller has already checked that the stroke is going the finger's
    /// plucking way, so the line this credits is one the fingertip went *through*
    /// rather than one it merely travelled back past.
    private static func attributedPluck(fromX x0: CGFloat,
                                        toX x1: CGFloat,
                                        travel: CGFloat,
                                        across: CGFloat,
                                        reversed: Bool) -> Int? {
        let neck = VirtualPipaGeometry.neck
        let spacing = neck.width / CGFloat(VirtualPipaGeometry.stringCount + 1)
        // drawPipa places string s at (s + 1) / (stringCount + 1) of the width.
        let lines = (0..<VirtualPipaGeometry.stringCount)
            .map { neck.minX + spacing * CGFloat($0 + 1) }

        let lo = min(x0, x1)
        let hi = max(x0, x1)
        let crossed = lines.indices.filter { lines[$0] > lo && lines[$0] < hi }

        if across >= crossingAcrossRatio {
            // The first line the stroke meets, in the direction it is going.
            let hit = x1 >= x0 ? crossed.min { lines[$0] < lines[$1] }
                               : crossed.max { lines[$0] < lines[$1] }
            if let hit {
                return reversed ? VirtualPipaGeometry.stringCount - 1 - hit : hit
            }
        }

        guard travel >= guessTravelThreshold, across >= guessAcrossRatio else { return nil }
        let middle = (x0 + x1) / 2
        guard middle >= neck.minX - spacing / 2, middle <= neck.maxX + spacing / 2 else {
            return nil
        }
        return lines.indices
            .min { abs(lines[$0] - middle) < abs(lines[$1] - middle) }
            .map { reversed ? VirtualPipaGeometry.stringCount - 1 - $0 : $0 }
    }

    /// Velocity for a flick, from how far the fingertip travelled in one frame.
    /// A flick just past the threshold is the softest sound the instrument can
    /// make; one that carries `fullVelocityTravel` or further is full force.
    /// Travel is in screen widths, the unit the thresholds are stated in, and
    /// the scale starts at the threshold of *that finger* — a thumb stroke that
    /// clears its own lower bar is as much a pluck as an index stroke that
    /// clears the higher one.
    private func pluckVelocity(for travel: CGFloat, threshold: CGFloat) -> Double {
        let span = max(fullVelocityTravel - threshold, 0.001)
        let position = min(max((travel - threshold) / span, 0), 1)
        let low = pluckVelocityRange.lowerBound
        return low + Double(position) * (pluckVelocityRange.upperBound - low)
    }

    /// Map the left index fingertip to a position on the drawn neck, or `nil`
    /// when it is outside it.
    ///
    /// The point that picks the note is the one that actually stops the string:
    /// the fingertip, not the wrist. A wrist sits about a hand's length behind
    /// the finger, so it lands several positions lower and shifts sideways with
    /// every wrist roll — the marker moved when the player was only turning the
    /// hand, and lagged when they reached up the neck. The fingertip has neither
    /// problem.
    ///
    /// Vision uses a bottom-left origin; the Canvas uses top-left, so y is
    /// flipped exactly once here — the same `(1 - l.y)` the skeleton overlay
    /// uses. That single flip makes the marker track the hand on screen.
    private static func mapSelection(_ kps: [HandKeypoint],
                                     stringOrderReversed: Bool,
                                     invertFret: Bool,
                                     fretCount: Int) -> PipaSelection? {
        guard let tip = Self.indexFingerPoint(kps) else {
            return nil
        }
        let screenX = tip.x
        let screenY = 1 - tip.y

        let neck = VirtualPipaGeometry.neck
        guard screenX >= neck.minX, screenX <= neck.maxX,
              screenY >= neck.minY, screenY <= neck.maxY else {
            return nil
        }
        guard let string = Self.stringForX(screenX,
                                           reversed: stringOrderReversed) else {
            return nil
        }

        let relY = (screenY - neck.minY) / neck.height
        let row = min(fretCount, max(0, Int(relY * CGFloat(fretCount + 1))))
        let fret = invertFret ? (fretCount - row) : row
        return PipaSelection(string: string, fret: fret)
    }

    /// The stopping point of the left index finger: the tip when Vision is
    /// confident about it, otherwise the joints behind it, in order.
    ///
    /// Reading only `indexTip` would drop the note whenever the fingertip is
    /// soft-edged or partly hidden behind its own shadow, and a dropped reading
    /// freezes the last note instead of updating it. The DIP and PIP joints sit
    /// on the same finger a centimetre or two back, so using them for a frame is
    /// far closer than falling through to anything else.
    ///
    /// There is deliberately no wrist fallback. With the hand cropped by the
    /// frame edge Vision guesses a wrist and puts it on the other side of the
    /// palm; falling back to it would hand the pitch to a point that is not on
    /// the hand at all. Losing every joint of the finger instead means "not
    /// pressing", which now sounds the open string — the honest answer.
    private static func indexFingerPoint(_ kps: [HandKeypoint]) -> CGPoint? {
        for name in ["indexTip", "indexDIP", "indexPIP"] {
            if let kp = kps.first(where: { $0.name == name }),
               kp.confidence > 0.3 {
                return kp.location
            }
        }
        return nil
    }

    /// Map a normalized screen x onto one of the four drawn strings (0..3), or
    /// nil when the point is outside the neck. Both the left index fingertip
    /// and the right plucking fingertip use this same function, so "the same
    /// string" means the
    /// same band of the neck for both hands. Nothing is clamped: outside the
    /// neck is outside every string.
    private static func stringForX(_ screenX: CGFloat, reversed: Bool) -> Int? {
        let neck = VirtualPipaGeometry.neck
        let r = (screenX - neck.minX) / neck.width
        guard r >= 0, r <= 1 else { return nil }
        let last = VirtualPipaGeometry.stringCount - 1
        // drawPipa places string s at (s + 1) / (stringCount + 1) of the neck
        // width, so snap to the nearest drawn line rather than four equal bands.
        let col = min(last, max(0, Int(round(r * CGFloat(VirtualPipaGeometry.stringCount + 1) - 1))))
        return reversed ? (last - col) : col
    }

    private static func noteName(string: Int, fret: Int, openFreqs: [Double]) -> String {
        let base = openFreqs[min(openFreqs.count - 1, max(0, string))]
        let freq = base * pow(2.0, Double(fret) / 12.0)
        return Self.noteName(freq: freq)
    }

    private static func noteName(freq: Double) -> String {
        guard freq > 0 else { return "" }
        let n = Int(round(12 * log2(freq / 440.0)))   // semitones from A4
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let idx = ((n + 9) % 12 + 12) % 12             // A4 -> index 9
        let octave = 4 + (n + 9) / 12
        return "\(names[idx])\(octave)"
    }
}
