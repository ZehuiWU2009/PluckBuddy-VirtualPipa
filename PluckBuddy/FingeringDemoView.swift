//
//  FingeringDemoView.swift
//  PluckBuddy
//
//  Smart Fingering Coach — offline reference demo.
//
//  Plays a bundled reference clip that shows a correct hand posture on the Pipa,
//  and runs the SAME Vision hand-pose pipeline (HandPoseExtractor) used by the
//  live coach — frame by frame — so a reviewer can watch the 21 landmarks, the
//  tiger-mouth angle, and live coaching feedback WITHOUT a real Pipa or a camera.
//
//  Fully offline: frames are decoded locally with AVAssetReader; nothing is sent
//  to the network. This is the no-instrument path for the Swift Student Challenge
//  three-minute experience.
//
//  Created by 吴泽荟（Zehui Wu） on 2026/11/13.
//

import SwiftUI
import AVFoundation
import Vision
import UIKit

/// Name of the bundled reference clip (no extension). Drop a short, close-up,
/// well-lit clip of a hand holding the Pipa into the app bundle and name it
/// exactly this (e.g. `FingeringDemo.mp4`).
let fingeringDemoVideoName = "FingeringDemo"

/// Replicates the tiger-mouth angle scoring used by TechniqueEvaluators.
/// Ideal spread: thumb–index angle ≈ 40° (30°–50° scores full marks).
private func scoreTigerMouth(_ degrees: Double) -> (score: Double, suggestion: String) {
    guard degrees >= 1 else {
        return (70, "Hold the Pipa so your hand is clearly visible to the camera.")
    }
    let diff = abs(degrees - 40)
    let score: Double
    if diff < 10 {
        score = 100
    } else if diff < 20 {
        score = 85
    } else if diff < 30 {
        score = 70
    } else {
        score = 50
    }
    let suggestion: String
    if score >= 80 {
        suggestion = "Tiger mouth opens naturally — good hand shape."
    } else {
        suggestion = "Open the tiger mouth a little so the thumb and index finger spread naturally."
    }
    return (score, suggestion)
}

/// Tiger-mouth angle (degrees) from the 21 keypoints.
/// Mirrors TechniqueCoachViewModel.calculateTigerMouthAngle:
/// the angle at the wrist between the thumb direction and the index direction.
private func tigerMouthAngle(from keypoints: [HandKeypoint]) -> Double {
    guard let wrist = keypoints.first(where: { $0.name == "wrist" })?.location,
          let thumb = keypoints.first(where: { $0.name == "thumbTip" })?.location,
          let index = keypoints.first(where: { $0.name == "indexTip" })?.location else {
        return 0
    }
    let v1x = Double(thumb.x - wrist.x), v1y = Double(thumb.y - wrist.y)
    let v2x = Double(index.x - wrist.x), v2y = Double(index.y - wrist.y)
    let len1 = sqrt(v1x * v1x + v1y * v1y)
    let len2 = sqrt(v2x * v2x + v2y * v2y)
    guard len1 > 0.001, len2 > 0.001 else { return 0 }
    let cosT = (v1x * v2x + v1y * v2y) / (len1 * len2)
    return acos(max(-1, min(1, cosT))) * 180 / .pi
}

/// Decodes a bundled video into CVPixelBuffers, offline and without a camera.
final class FingeringDemoFrameSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    /// - Parameter videoName: resource name (no extension) in the app bundle.
    init?(videoName: String) {
        guard let url = Bundle.main.url(forResource: videoName, withExtension: "mp4")
                      ?? Bundle.main.url(forResource: videoName, withExtension: "mov") else {
            return nil
        }
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return nil
        }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
    }

    /// Returns the next decoded frame, or nil when the clip is exhausted.
    func nextFrame() -> CVPixelBuffer? {
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else {
            return nil
        }
        return buffer
    }
}

/// Offline, no-instrument demo of the Smart Fingering Coach.
struct FingeringDemoView: View {
    @State private var overlayImage: UIImage?
    @State private var angle: Double = 0
    @State private var score: Double = 0
    @State private var suggestion: String = "Preparing…"
    @State private var isPlaying = false
    @State private var statusMessage: String?

    private let extractor = HandPoseExtractor()
    private let smoother = HandPoseSmoother()
    private let ciContext = CIContext(options: nil)

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Fingering Coach — Reference Demo")
                    .font(.headline)
                Text("Watch the coach read hand posture from a reference clip. No Pipa or camera required.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ZStack {
                    if let img = overlayImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    } else if let msg = statusMessage {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.12))
                            .overlay(Text(msg).foregroundStyle(.secondary).padding())
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.12))
                            .overlay(Text("Add \(fingeringDemoVideoName).mp4 to the app bundle").foregroundStyle(.secondary).padding())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 360)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tiger-Mouth Angle").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.0f°", angle)).font(.title2).bold()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Posture Score").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.0f", score)).font(.title2).bold()
                    }
                }
                .padding(.horizontal)

                Text(suggestion)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button(action: togglePlay) {
                    Label(isPlaying ? "Pause" : "Play Demo",
                          systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                Spacer()
            }
            .padding()
            .navigationTitle("Reference Demo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func togglePlay() {
        isPlaying.toggle()
        if isPlaying {
            statusMessage = nil
            Task { await runAnalysis() }
        }
    }

    private func runAnalysis() async {
        guard let source = FingeringDemoFrameSource(videoName: fingeringDemoVideoName) else {
            await MainActor.run {
                statusMessage = "Reference clip “\(fingeringDemoVideoName).mp4” not found in the app bundle."
                isPlaying = false
            }
            return
        }

        var smoothAngle: Double = 0
        var count = 0
        while isPlaying, let buffer = source.nextFrame() {
            guard let hands = try? await extractor.extractHands(from: buffer),
                  let hand = hands.max(by: { $0.keypoints.count < $1.keypoints.count }) else {
                continue
            }
            let kp = smoother.smooth(keypoints: hand.keypoints)
            let a = tigerMouthAngle(from: kp)
            guard a >= 1 else { continue }

            smoothAngle = count == 0 ? a : smoothAngle * 0.8 + a * 0.2
            count += 1
            let (s, sug) = scoreTigerMouth(smoothAngle)
            let img = drawOverlay(buffer: buffer, keypoints: kp)

            await MainActor.run {
                angle = smoothAngle
                score = s
                suggestion = sug
                overlayImage = img
            }
            try? await Task.sleep(nanoseconds: 33_000_000) // ~30 fps playback pace
        }
        await MainActor.run { isPlaying = false }
    }

    /// Render the video frame and draw the skeleton overlay on top.
    private func drawOverlay(buffer: CVPixelBuffer, keypoints: [HandKeypoint]) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        if let skeleton = HandPoseVisualizer.drawSkeleton(keypoints: keypoints, imageSize: size) {
            skeleton.draw(in: CGRect(origin: .zero, size: size))
        }
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}
