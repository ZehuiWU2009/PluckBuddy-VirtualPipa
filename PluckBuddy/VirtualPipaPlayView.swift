//
//  VirtualPipaPlayView.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/11/13.
//
//  SSC "play without a Pipa" screen: a camera feed with a 2D virtual Pipa
//  overlay. Only the neck itself is drawn — the sensing rules stay in
//  VirtualPipaController, with no border around the active area and no
//  on-screen instructions. All sound is synthesized by ElectricPipa through
//  VirtualPipaEngine; no real instrument, mic or network.

import SwiftUI
import AVFoundation
import UIKit

struct VirtualPipaPlayView: View {
    @StateObject private var controller = VirtualPipaController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CameraPreview(session: controller.camera.session)
                .ignoresSafeArea()

            Canvas { context, size in
                drawPipa(context: context, size: size, selection: controller.selection)
                drawHands(context: context, size: size, hands: controller.hands)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .shadow(radius: 3)
                    }
                    Spacer()
                    Text(controller.noteLabel.isEmpty ? "—" : controller.noteLabel)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
                .padding()

                Spacer()

                if let err = controller.engineError {
                    VStack(spacing: 8) {
                        Text(err)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.red)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button {
                            controller.retryEngine()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(Color.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            if VirtualPipaController.showPluckDiagnostics, !controller.pluckDiagnostics.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Text(controller.pluckDiagnostics)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Spacer()
                    }
                    .padding(.bottom, 6)
                }
            }

            if !controller.isRunning {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("Play Pipa with your hands")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Button {
                        controller.start()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 200, height: 52)
                            .background(Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
        .onDisappear {
            controller.stop()
        }
    }

    // MARK: - Canvas drawing

    private func drawPipa(context: GraphicsContext, size: CGSize, selection: PipaSelection?) {
        // Same geometry the gesture controller maps against — never hard-code a
        // different neck here or the hands and the strings drift apart.
        let neck = VirtualPipaGeometry.neck
        let x0 = neck.minX * size.width
        let y0 = neck.minY * size.height
        let neckW = neck.width * size.width
        let neckH = neck.height * size.height
        let strings = VirtualPipaGeometry.stringCount
        let positions = VirtualPipaGeometry.positionCount

        // Fret lines (0 = open string, up to 7).
        for i in 0...positions {
            let y = y0 + neckH * CGFloat(i) / CGFloat(positions)
            var path = Path()
            path.move(to: CGPoint(x: x0, y: y))
            path.addLine(to: CGPoint(x: x0 + neckW, y: y))
            context.stroke(path, with: .color(.white.opacity(0.22)), lineWidth: 1)
        }

        // String lines.
        for s in 0..<strings {
            let x = x0 + neckW * CGFloat(s + 1) / CGFloat(strings + 1)
            var path = Path()
            path.move(to: CGPoint(x: x, y: y0))
            path.addLine(to: CGPoint(x: x, y: y0 + neckH))
            context.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 2)
        }

        // Selection marker.
        if let sel = selection {
            let sx = x0 + neckW * CGFloat(sel.string + 1) / CGFloat(strings + 1)
            let sy = y0 + neckH * CGFloat(sel.fret) / CGFloat(positions)
            context.fill(Path(ellipseIn: CGRect(x: sx - 11, y: sy - 11, width: 22, height: 22)),
                         with: .color(.yellow))
        }
    }

    private func drawHands(context: GraphicsContext, size: CGSize, hands: [DetectedHand]) {
        let connections: [(String, String)] = [
            ("wrist", "thumbCMC"), ("wrist", "indexMCP"), ("wrist", "middleMCP"),
            ("wrist", "ringMCP"), ("wrist", "littleMCP"),
            ("thumbCMC", "thumbMP"), ("thumbMP", "thumbIP"), ("thumbIP", "thumbTip"),
            ("indexMCP", "indexPIP"), ("indexPIP", "indexDIP"), ("indexDIP", "indexTip"),
            ("middleMCP", "middlePIP"), ("middlePIP", "middleDIP"), ("middleDIP", "middleTip"),
            ("ringMCP", "ringPIP"), ("ringPIP", "ringDIP"), ("ringDIP", "ringTip"),
            ("littleMCP", "littlePIP"), ("littlePIP", "littleDIP"), ("littleDIP", "littleTip")
        ]

        for hand in hands {
            // With the hand half out of frame Vision still reports all 21 points
            // and guesses the ones it cannot see. The wrist is the usual victim:
            // it lands on the other side of the palm, and five long bones fan out
            // of empty space. Dropping just that one point leaves the fingers
            // drawn and the fan gone.
            var dict = Dictionary(uniqueKeysWithValues: hand.keypoints.map { ($0.name, $0.location) })
            if HandGeometry.wristLooksInvented(hand.keypoints, imageSize: size) {
                dict.removeValue(forKey: "wrist")
            }
            let point: (String) -> CGPoint? = { name in
                guard let l = dict[name] else { return nil }
                return CGPoint(x: l.x * size.width, y: (1 - l.y) * size.height)
            }

            for (a, b) in connections {
                if let pa = point(a), let pb = point(b) {
                    var path = Path()
                    path.move(to: pa)
                    path.addLine(to: pb)
                    context.stroke(path, with: .color(.pink), lineWidth: 2)
                }
            }
            for kp in hand.keypoints where dict[kp.name] != nil {
                let p = CGPoint(x: kp.location.x * size.width, y: (1 - kp.location.y) * size.height)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                             with: .color(.blue))
            }
        }
    }
}

// MARK: - Camera preview layer

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        view.tag = 100
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = uiView.bounds
        }
    }
}
