# 虚拟琵琶 — 手上没有琴也能练　／　PluckBuddy VirtualPipa — Practice Without the Instrument

> 本 README 英文在前、中文在后。
> This README is in English first, then Chinese.

---

# PluckBuddy VirtualPipa — Practice Without the Instrument

An iOS app for practising Pipa fingering with no instrument in hand. The camera reads both hands against a virtual Pipa drawn on screen: the left hand chooses the string and the fret, the right hand plucks and sweeps, and the sound is a modal model fitted to recordings of my own Pipa, rendered on the device. The tuner, the Fingering Coach, the three practice companions and the metronome are all here as in the bilingual edition; this edition adds the virtual instrument on top.

> Personal project · grown out of my own Pipa practice, still evolving
>
> Developer: Zehui Wu (吴泽荟)
> School: Wuhan Cogdel Cranleigh High School (武汉康礼高级中学)

## Recognition

- **First Prize**, Qihang Track, Primary & Secondary School Division, at the 2026 Mobile Application Innovation Contest, part of the China Collegiate Computing Contest (CCCC).
- Demonstrated the project live on stage at the conference as the **only primary/secondary-school representative**.
- Conference photos, the stage presentation and demonstration videos, and the English feature deck are archived in [PluckBuddy-Bilingual's `docs/CCCC-MAIC/`](https://github.com/ZehuiWU2009/PluckBuddy-Bilingual/tree/main/docs/CCCC-MAIC/).

## Availability & Press

- **Now on the App Store**: [PluckBuddy](https://apps.apple.com/cn/app/pluckbuddy/id6824425608) is available for download on iOS.
- **Interview with Apple**: Apple interviewed the developer, Zehui Wu, and published [「移动应用创新赛，听听她的好点子」](https://www.xiaohongshu.com/discovery/item/6af032540000000015009ff2?xsec_token=ABGYVgZb2HZKZH8hneihDgHhve3lu9lVEoICv6WdHYOwk=&xsec_source=pc_share) on its official Xiaohongshu account @Apple.

## Technical Contributions of This Project

The project makes technical innovations and engineering trade-offs in the following seven directions.

### Contribution 1 · A Virtual Pipa Whose Voice Is Measured, Not Modelled

The virtual instrument does not synthesise from physical laws. It plays back what the instrument actually did: the four open strings were recorded, and each recording was taken apart into the modes that make it up. A waveguide can tell you how a string behaves in general; only a measurement can tell you how *this* Pipa sounds.

- **259 modes, measured one by one**: 44 on the thin string, then 59, 66, and 90 on the thick one. Each mode carries its own frequency ratio to the fundamental, its own amplitude, its own gain and phase per channel, and a two-stage decay — a fast part and a slow one — because a real partial does not fall away at a single rate. The slowest decay on the thick string is 9.5 s against 0.04 s for the highest partials of the thin string, which is why the low string is still sounding after everything above it has gone
- **Beating kept rather than averaged out**: 19 of the 259 modes are not single sinusoids but pairs split by less than a hertz, with a fixed phase offset between them. They are what makes a held note shimmer. One oscillator at the average frequency sounds dead, and that is the first thing the ear catches
- **The part the partials cannot explain, kept as its own layer**: the noise of the nail, the knock of the body, the tail of a neighbouring string are stored per string as a 1.5 s stereo residual and rendered alongside the modes. Asking a set of sinusoids to reproduce a transient is exactly how synthetic instruments come to sound synthetic
- **Cross-string coupling from the same takes**: a pluck on one string still excites the other three through the bridge, and the coupling is measured from the recordings rather than estimated
- **Nothing is taken on trust**: each string's accepted render is compared against the model's output item by item, and the worst truncation error recorded in `provenance.json` is 2e-10, so a refactor across 259 modes cannot quietly change the sound. If a resource goes missing the app falls back to the Karplus–Strong waveguide rather than going silent

### Contribution 2 · Audio-Video Multimodal Fusion for Fingering Detection

PluckBuddy fuses three signals — Vision hand landmarks, an FFT spectrum and a CoreML classifier — to decide among four fingering types: Pluck, Tremolo, Sweep and Long Tone.

- **Audio side**: the Accelerate framework performs a 4096-point FFT to estimate pitch and rhythm in real time; at the same time the 48 kHz hardware buffer is linearly interpolated and downsampled to 16 kHz and fed to the CoreML classifier as the gate that decides "is this a Pipa"
- **Video side**: Vision tracks 21 hand landmarks; after Kalman-filter smoothing it computes the tiger-mouth angle and wrist height as the geometric features for technique decisions
- **Fusion strategy**: audio decides "is this a Pipa sound" (ruling out speech / ambient noise); video decides "is the hand shape correct"; only when both pass does the pipeline enter technique classification, avoiding single-modality misjudgment

### Contribution 3 · On-Device Self-Trained CoreML Pipa Sound Classifier

A self-trained four-class model is built in: `PipaSoundClassifier.mlmodel`. Its input is Float32 `audioSamples`, 15600 frames long, which is about a 0.975-second window at 16 kHz, and it outputs four class probabilities:

| Class             | Meaning        |
| ----------------- | -------------- |
| `pipa`            | Pipa sound     |
| `other_instrument`| Other instrument |
| `speech`          | Human speech   |
| `background`      | Background noise |

- **On-device inference**: runs on the iPhone Neural Engine via `MLModel.prediction`; a single inference takes under 80 ms
- **Zero network dependency**: the whole inference is completed locally; no audio clip is ever uploaded
- **Precision optimization at the engineering layer**: the model itself is untouched. The threshold is 0.35 with a 2-frame moving average, plus energy gating that classifies low-RMS frames as background, and the inference step is 8000 frames instead of 15600 so consecutive windows overlap
- **Training data published**: the four-class recordings used to train this model are released as a standalone dataset asset — see Contribution 4 below

### Contribution 4 · An Open Pipa Sound Dataset Published as a Reusable Data Asset

The classifier above is only as good as the audio behind it, so that audio is published on its own rather than kept private. The training corpus behind `PipaSoundClassifier.mlmodel` lives in one place: the standalone repository [github.com/ZehuiWU2009/PipaSoundClassifierDataset](https://github.com/ZehuiWU2009/PipaSoundClassifierDataset), released under CC BY 4.0, where all 887 MB of real audio is tracked with Git LFS. Neither app repository carries a copy of the audio. Both PluckBuddy-Bilingual and PluckBuddy-VirtualPipa draw their sound gate from this one dataset, so it is a shared asset rather than a fixture of a single app.

- **What it holds**: 43 clips in total, roughly 887 MB, split into the four classes the gate needs — `pipa/` 7 clips of my own playing across different techniques, `other_instrument/` 24 clips of instruments I play myself plus three AI-generated guzheng pieces, `speech/` 6 clips of my own voice, `background/` 6 clips of everyday ambience
- **Every clip is cleared for release**: each one is either self-recorded, contributed by family with permission, or AI-generated, so nothing third-party is republished
- **A documented sampling pipeline**: every recording is mixed to mono, resampled to 16 kHz by linear interpolation, and sliced into 15,600-sample windows of about 0.975 s advancing at 50% overlap, then fed to the classifier as raw waveform — the same window the released model takes
- **Provenance kept visible**: 25 clips carry a 640×480 video track alongside the audio, stored as `.mp4` through Git LFS, so a listener can confirm what was actually played; training consumes only the audio
- **Why it is a data asset rather than a footnote**: the negative classes are what make the gate useful, and negative audio is the hardest kind to collect. Publishing it means anyone can retrain the gate on the same footing instead of guessing at what "not a Pipa" should sound like

### Contribution 5 · Real-Time Algorithms: 4096-Point FFT + Kalman Filtering

- **FFT spectrum analysis**: `DSPFeatureExtractor.swift` uses `vDSP_fft_zrip` (Accelerate-accelerated) to perform a 4096-point FFT and computes RMS, harmonic ratio, spectral centroid, zero-crossing rate and other indicators, which serve as the input features for pitch detection and the classifier
- **Kalman filter smoothing**: the 21 landmarks obtained by `HandPoseExtractor` jitter on every frame, and using them directly introduces noise; after Kalman-filter smoothing, the tiger-mouth angle and wrist height are computed, giving a stable output of the tiger-mouth opening in degrees
- **Parallel processing**: the microphone 4096-frame buffer and camera frames are captured on two independent threads without blocking each other; CoreML inference runs on the `inferenceQueue` serial queue and does not contend with the audio main thread

### Contribution 6 · Unified Audio Pipeline + Model Gating Architecture

On iOS, several modules all want the microphone, but the AVAudioEngine tap can only be installed by one processor — concurrent access from multiple modules conflicts directly. PluckBuddy's solution:

```
┌──────────────────────────────────────────────────┐
│ AudioManager (singleton)                         │
│ ├── AVAudioEngine                                │
│ ├── 4096-frame tap                              │
│ └── startListening { buffer in                   │
│     ├─→ Smart Tuner: PipaSoundGate (gate)        │
│     │   + PitchDetector                          │
│     ├─→ Pluck Run: RhythmDetector                │
│     ├─→ Tremolo Bloom: RollDetector              │
│     └─→ Sweep Wave: SweepDetector                │
│    }                                             │
└──────────────────────────────────────────────────┘
```

- A single AVAudioEngine and a single tap; all modules that need audio share one buffer callback
- `PipaSoundGate` loads `PipaSoundClassifier.mlmodel` independently and **does not take over the AVAudioEngine tap** — it only takes over "downsampling + model inference", avoiding resource contention with the Fingering Coach's Engine

### Contribution 7 · Fully Offline On-Device Five-Layer Architecture

See the next section, System Architecture, for the detailed diagram. Core innovations:

- The five layers, from bottom to top, are audio/video capture, signal processing, model inference, metric evaluation, and interaction and presentation. Each has a single responsibility and stays decoupled from the rest
- Capture, feature extraction, inference and evaluation each run on their own queue; the main thread only refreshes the UI
- Practice recordings, scores and leaderboards are all written to local CoreData. Nothing is uploaded and nothing is downloaded

## System Architecture

It adopts a fully offline on-device five-layer architecture: everything from raw microphone / camera data to UI feedback is completed on the iPhone, with no network dependency whatsoever.

How each layer maps to the code is shown below.

```mermaid
flowchart TB
    subgraph L1 ["Layer 1 · Audio/Video Capture"]
        A1["AVAudioEngine microphone tap<br/>Hardware 48 kHz, 4096 frames / frame"]
        A2["AVCaptureSession camera<br/>Vision 21 hand landmarks"]
    end
    subgraph L2 ["Layer 2 · Signal Processing"]
        B1["FFT spectrum + harmonic ratio + spectral centroid<br/>(DSPFeatureExtractor)"]
        B2["48 kHz → 16 kHz linear interpolation downsampling<br/>Mono mixing"]
    end
    subgraph L3 ["Layer 3 · Model Inference (CoreML)"]
        C1["PipaSoundClassifier<br/>Four classes: Pipa / other instrument / speech / background<br/>Input: 15600 frames @ 16 kHz sliding window"]
    end
    subgraph L4 ["Layer 4 · Metric Evaluation"]
        D1["Pitch detection (PitchDetector)"]
        D2["Beat / tremolo / sweep detectors"]
        D3["Technique classification (VisionTechniqueClassifier)<br/>Pluck / Tremolo / Sweep / Long Tone / Noise<br/>Metrics from TechniqueEvaluators"]
    end
    subgraph L5 ["Layer 5 · Interaction & Presentation"]
        E1["SwiftUI view layer<br/>Real-time waveform + score card + quantitative metrics"]
        E2["Lottie animations<br/>Track character / petal bloom / water ripple"]
    end

    L1 --> L2 --> L3 --> L4 --> L5

    %% Horizontal details
    A1 --> B2 --> C1 --> D1
    A2 --> D3
    D1 --> E1
    D2 --> E2
    D3 --> E1
```

**Responsibilities of the Five Layers**

| Layer                       | Input                                | Output                                    | Key files                                                                                                                        |
| --------------------------- | ------------------------------------ | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| 1 · Audio/Video Capture     | The user playing in front of iPhone   | Raw PCM stream / camera frames             | `AudioManager.swift`, `VideoCaptureManager.swift`, `CameraManager.swift`                                                          |
| 2 · Signal Processing       | Raw PCM                              | Spectral features / 16 kHz normalized samples | `DSPFeatureExtractor.swift`, `PipaSoundGate.swift` (downsampling)                                                             |
| 3 · Model Inference         | 15600 normalized frames             | 4-class probability distribution           | `PipaSoundClassifier.mlmodel`, `PipaSoundGate.swift` (inference)                                                                 |
| 4 · Metric Evaluation       | Spectral features + video landmarks  | Pitch / beat / technique decisions          | `PitchDetector.swift`, `RhythmDetector.swift`, `RollDetector.swift`, `SweepDetector.swift`, `TechniqueEvaluators.swift`, `VisionTechniqueClassifier.swift`, `HandPoseAnalyzer.swift` |
| 5 · Interaction & Presentation | Metric data                        | User-visible UI and animations              | 22 `*View.swift` files + `Animations/*.json` + `LottieRunnerView.swift`                                                            |

**A Second Path Runs Beside This One**

The five layers above describe how a performance is *judged*. The virtual Pipa makes sound instead, and it takes a different route: camera frames → `HandPoseExtractor` → `VirtualPipaController` → `VirtualPipaEngine` → `VirtualPipaCore`. It shares layer 1 and the 21 landmarks, but takes nothing from layers 2 to 4 — the virtual instrument never opens the microphone, so a pluck is a hand movement and not a sound, and no classifier stands between the finger and the string. `VirtualPipaController` holds the whole gesture logic: which string the left hand is on, which fret, whether a fingertip stroke is a pluck or the arm carrying the hand. The coach's reference demo runs the other way: frames decoded from the bundle are fed into the same `HandPoseExtractor`, which is why landmarks, tiger-mouth angle and coaching feedback all appear with no camera and no Pipa.

**Why It Is Layered This Way**

- Layer 1 focuses on capture: all I/O sits in one place, so multiple modules never fight over the AVAudioEngine tap
- Layer 2 normalizes formats: it converts the hardware 48 kHz into the 16 kHz 15600-frame window the model needs, so downstream components can be fed data without caring where it came from
- Layer 3 runs CoreML inference: under 80 ms per pass, fully offline
- Layer 4 holds the domain logic of playing: 5 detectors each cover one dimension and can be tested on their own
- Layer 5 only renders: SwiftUI subscribes to the ViewModel Published state and does no computation

## Core Features

| Module                    | Description                                                                                                                                                              |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Smart Fingering Coach** | Recognizes left/right hand shapes in real time with the camera (Vision framework), matches the 5 core Pipa techniques (Pluck / Tremolo / Sweep / Long Tone / Noise), and produces frame-stable technique scores plus a rotating carousel of core requirements. Two entries need no instrument at all: a reference demo that plays a bundled clip through the same Vision pipeline, and a play mode on the virtual Pipa |
| **Virtual Pipa**          | Plays with no instrument in hand. A virtual Pipa drawn on screen is driven by the camera: the left hand chooses string and fret, the right hand plucks or sweeps. The voice is a modal model fitted to recordings of a real Pipa's four open strings and rendered on the device, offline |
| **Smart Tuner**           | The microphone captures the open-string sound of the Pipa; a self-developed FFT algorithm reports the current pitch and its cents deviation from the twelve-tone equal temperament standard. A CoreML classifier is wired in as gating: "decide Pipa sound first → then decide pitch" |
| **Pluck Run**             | Gamified beat-track accompaniment in two modes. Watch demo plays a scripted performance with no microphone; Play along gives you four on-screen strings and every pluck moves the character one step. Both track beat stability, BPM and the total score |
| **Tremolo Bloom**         | Tremolo training visualized as a growing flower. It detects the evenness of consecutive fast plucks, and petals bloom after one round is completed                            |
| **Sweep Wave**            | Sweep training visualized as water ripples. It distinguishes up-sweep / down-sweep and generates a ripple animation in the corresponding direction                            |
| **Metronome**             | Independently adjustable BPM metronome, adapted to different practice scenarios                                                                                              |
| **Social Hub**            | Offline leaderboard / achievements / friend PK (local persistence, for demo purposes)                                                                                        |
| **Welcome Screen**        | Off-white background + Logo + "Let's practice 5 minutes today too" + 3-second countdown auto-dismiss + "Skip" in the top-right corner                                        |

## Tech Stack

- The app is written in Swift 6, with SwiftUI for the interface, Combine for state binding, and Swift Concurrency in strict mode
- It runs on arm64 devices with iOS 17.6 or later, and the camera and microphone features must be demonstrated on a real device
- On the algorithm side, vDSP from the Accelerate framework does the FFT, AVAudioEngine handles microphone capture, and Vision extracts hand landmarks
- The acoustic model is the self-trained CoreML classifier PipaSoundClassifier, which separates Pipa, other instruments, speech and background noise, entirely offline
- The virtual Pipa's voice is a modal model fitted to recordings of my own Pipa: each open string carries its own partials with individual decay, stereo gain and phase, plus a residual layer, all rendered on the device; a Karplus–Strong waveguide stays in the app as the fallback
- Audio capture goes through the custom AudioManager, which installs one tap of 4096 frames per buffer and then linearly interpolates the hardware 48 kHz down to 16 kHz
- Hand shape comes from HandPoseExtractor, which returns 21 landmarks per hand, from which the tiger-mouth angle and wrist height are computed
- Lottie drives the sweep water-ripple and track-character animations, and CoreData keeps practice records, leaderboards and achievements on the device

## Project Structure

```
PluckBuddy/
├── PluckBuddy.xcodeproj/       # Xcode project
├── PluckBuddy/                 # Main target source
│   ├── PluckBuddyApp.swift               # App entry (welcome/home switching)
│   ├── ContentView.swift                 # Root container: welcome page, then home
│   ├── WelcomeView.swift                 # Launch welcome page (3-second countdown fade-out)
│   ├── HomeView.swift                    # Home page (entries to the seven modules)
│   ├── MainMenuExample.swift             # Menu card layout behind the home page
│   ├── Localization.swift                # L() lookup, LanguageManager, bundle switching
│   ├── LanguageSettingView.swift         # Follow system / 简体中文 / 繁體中文 / English
│   ├── en.lproj/                         # English Localizable.strings
│   ├── zh-Hans.lproj/                    # Simplified Chinese table (identity mapping; the keys are the Chinese text)
│   ├── zh-Hant.lproj/                    # Traditional Chinese table
│   ├── TechniqueCoachView.swift          # Smart Fingering Coach screen
│   ├── TechniqueCoachViewModel.swift     # Its state: frames, scores, report gate
│   ├── TechniqueType.swift               # The five techniques and their naming
│   ├── TechniqueEvaluators.swift         # Per-technique metric evaluation
│   ├── TechniqueRequirementsManager.swift # Rotating carousel of core requirements
│   ├── VisionTechniqueClassifier.swift   # Landmarks → technique, with majority-vote smoothing
│   ├── HandPoseExtractor.swift           # Vision hand shape extraction, 21 landmarks per hand
│   ├── HandPoseAnalyzer.swift            # Smoothing, tiger-mouth angle, invented-wrist filter
│   ├── CameraPreviewView.swift           # Camera preview layer with the landmark overlay
│   ├── VideoCaptureManager.swift         # Frame output feeding the coach pipeline
│   ├── VideoRecorder.swift               # Records the clip attached to a report
│   ├── FingeringDemoView.swift           # Reference demo: a bundled clip run through the live Vision pipeline
│   ├── CoachReport.swift                 # Report model, repertoire and session audio analysis
│   ├── CoachReportStore.swift            # Local report persistence
│   ├── CoachReportView.swift             # The report page
│   ├── PracticePieceCulture.swift        # Cultural notes for each practice piece
│   ├── PracticeSession.swift             # One practice session record
│   ├── PracticeDataManager.swift         # Daily stats and history
│   ├── TunerView.swift                   # Smart Tuner screen
│   ├── TunerViewModel.swift              # Pitch, cents deviation and string naming
│   ├── PipaSoundGate.swift               # Tuner-only Pipa-sound gate, loading the model on its own so it never fights the coach for the AVAudioEngine tap
│   ├── PipaSoundClassifier.mlmodel       # On-device four-class CoreML model
│   ├── RunningPracticeView.swift         # Pluck Run screen: Watch demo and Play along modes
│   ├── RunningViewModel.swift            # Pluck Run ViewModel
│   ├── RunningDemoViews.swift            # Runner sprite, track and the scripted demo video
│   ├── PipaOpenStringsPad.swift          # The four on-screen strings both Pluck Run modes share
│   ├── LottieRunnerView.swift            # Lottie-driven runner animation
│   ├── FlowerPracticeView.swift          # Tremolo Bloom UI
│   ├── FlowerViewModel.swift             # Tremolo Bloom ViewModel
│   ├── FlowerSettingsSheet.swift         # Tremolo Bloom settings
│   ├── WavePracticeView.swift            # Sweep Wave UI
│   ├── WaveViewModel.swift               # Sweep Wave ViewModel
│   ├── WaveSettingsSheet.swift           # Sweep Wave settings
│   ├── MetronomeView.swift               # Metronome UI
│   ├── MetronomeManager.swift            # Metronome scheduling
│   ├── VirtualPipaPlayView.swift         # Virtual Pipa screen, neck drawing and hand overlay
│   ├── CameraManager.swift               # Camera capture for the virtual instrument
│   ├── VirtualPipaController.swift       # Turns both hands into string + fret + pluck events
│   ├── VirtualPipaEngine.swift           # Audio session, source node and pluck / sweep entry points
│   ├── VirtualPipaCore/                  # Sound engine: measured modal voice, waveguide fallback, tuning
│   │   ├── PipaKitModel.swift            # Loads and validates model.json, the four presets and the provenance record
│   │   ├── PipaKitVoice.swift            # One sounding note: every partial of a string, with its own decays, split pair and residual
│   │   ├── PipaKitSynth.swift            # Four-string voice pool, cross-string coupling and the stereo mix
│   │   ├── PipaSoundEngine.swift         # Thin wrapper that owns the source node output
│   │   ├── PipaSynth.swift               # Karplus–Strong four-string engine kept as the fallback
│   │   ├── PipaString.swift              # One waveguide: delay line, loop filter and excitation
│   │   ├── PipaBody.swift                # Body resonances: one low shelf plus five peaking bands
│   │   ├── PipaTuning.swift              # Open-string MIDI notes, fret table and pitch conversion
│   │   └── PipaAudioCore.swift           # Real-time loop and the lock-free command queue
│   ├── KitResources/                     # Fitted model for the four open strings (model.json, provenance, four residual layers)
│   ├── AudioManager.swift                # Unified audio capture
│   ├── DSPFeatureExtractor.swift         # Self-developed FFT spectral features
│   ├── PitchDetector.swift               # Pitch detection
│   ├── PitchDetectorTests.swift          # Unit tests for the pitch detector
│   ├── RhythmDetector.swift              # Pluck beat detection
│   ├── RollDetector.swift                # Tremolo detection
│   ├── SweepDetector.swift               # Sweep detection
│   ├── SocialSquareView.swift            # Social hub
│   ├── FriendPKView.swift                # Friend PK
│   ├── AchievementView.swift             # Achievements
│   ├── RankingListView.swift             # Offline leaderboard
│   ├── SocialModels.swift                # Ranking, achievement and friend models with mock data
│   ├── ResultView.swift                  # Scores and report history
│   ├── ScrollingTextView.swift           # Scrolling banner text
│   ├── EnhancedScrollingBanner.swift     # Banner component
│   ├── ScrollingTextTestView.swift       # Banner preview screen
│   ├── Persistence.swift                 # CoreData persistence
│   ├── PluckBuddy.xcdatamodeld/          # CoreData model
│   ├── PrivacyInfo.xcprivacy             # Privacy manifest
│   ├── Animations/                       # Lottie animation JSON
│   └── Assets.xcassets/                  # Assets (Logo, app icon)
└── PluckBuddyTests/            # Unit test target
```

## How to Run

1. **Open** `PluckBuddy.xcodeproj` **with Xcode 17+ on a Mac**
2. Select the project on the left → TARGETS `PluckBuddy` → **Signing & Capabilities**
   - **Team**: choose your own Apple ID (a free account is enough)
   - **Bundle Identifier**: change it to one that is not registered under your account, e.g. `com.yourname.pluckbuddy`. The bilingual edition uses the bundle id `com.zehuiwu.pluckbuddy.bilingual` so that it differs from the Chinese edition (弹拨搭子) and the international edition (PluckBuddy); all three can be installed on the same iPhone at the same time
3. Connect a real device → pick iPhone in the device bar at the top → `Cmd+R`
4. **Real-device system requirement**: iOS 17.6 or later
5. **First time on a real device**: Settings → Privacy & Security → Developer Mode → turn it on and restart; when the app launches and reports "Untrusted Developer", go to Settings → General → VPN & Device Management → trust your Apple ID
6. **Camera / microphone modules** (Fingering Coach / Smart Tuner / the three companions) **must run on a real device**; the Simulator has no camera or microphone

The provisioning profile of a free Apple ID expires after 7 days; when it expires, reconnect to Xcode and re-sign to install again.

## Version History

v1.0 through v1.3 were built as the Chinese edition between late September and early October 2026, each round driven by problems exposed by on-device testing. In parallel an English-only edition was developed from the same codebase. Both older editions are now archived; this repository unifies the line as PluckBuddy 2.0 and is the only maintained edition going forward. The commit history continues from the Chinese edition, so this repository shows the full trajectory from the first runnable build to today in one continuous timeline.

### v1.0 · First complete edition (2026-09-29)

- All seven modules completed: Smart Fingering Coach, Smart Tuner, Pluck Run, Tremolo Bloom, Sweep Wave, Metronome and Social Hub
- Both audio and video pipelines working; the on-device CoreML four-class model is wired into the Fingering Coach
- 52 Swift files, about 13,700 lines

### v1.1 · Tuner gating and classifier precision (2026-09-30)

- The Tuner gains an on-device Pipa-sound gate with the new `PipaSoundGate.swift`. It does not take over the AVAudioEngine tap; it only handles downsampling and inference, while `AudioManager` still dispatches the microphone data, avoiding contention with the Fingering Coach and the three companions
- Gating rule: pitch calculation starts only when a Pipa sound is detected within the last 0.5 s; other frames show "Listening… waiting for Pipa"
- Engineering-layer classifier precision tuning: on-device tests showed Pipa probability mostly between 0.3 and 0.7, so the threshold dropped from 0.5 to 0.35, the moving-average window from 3 to 2 frames, an energy gate classifies frames with RMS below 0.01 as background noise, and the inference step changed from 15600 to 8000 frames for roughly 50% overlap
- Welcome screen changed to fade out before removal with an `isDismissing` guard, removing the race between the countdown hitting zero and the Skip button

### v1.2 · Hand metric and sample-rate convention (2026-10-01)

- Hand skeleton upgraded from a 6-point simplified drawing to the full 21-point skeleton: 5 fingertips as colored large dots, wrist as a blue dot, 15 mid joints as semi-transparent white small dots, plus 5 finger-bone lines and 5 palm lines
- Hand-score metric changed from finger angle to tiger-mouth angle: with the wrist as the vertex, the angle between the thumb direction and the index-finger direction. 30–50° scores full marks; too small means thumb and index are too close, too large means the tiger mouth is stretched too wide
- Sample rate unified to the real-device measured 48 kHz. Default values in the four detectors and four ViewModels changed from 44100 to 48000, eliminating the previous pitch-low-by-1.5-semitone and beat-slow-by-8.8% deviations. Unit tests still use self-synthesized 44100 signals and stay self-consistent
- Document finger-angle wording synced to tiger-mouth angle so reviewers see consistent terminology against the code

### v1.3 · Real-device warning clearance and release cleanup (2026-10-02)

- All 13 real-device build warnings cleared: 8 closures changed to explicit weak capture with early exit when the view is gone; 3 timer callbacks moved to read isolated properties on the main actor; 2 direction counters that were computed but never used were removed
- Chinese edition display name changed to 弹拨搭子, with the home title and microphone permission text updated in sync. The project name, target name and Bundle ID are unchanged, so the two editions can be installed side by side
- International edition app icon replaced with the English artwork across default, dark and tinted appearances; the Chinese edition welcome screen switched to the Chinese logo
   - Repository cleanup: architecture diagram and logo images, editable sources and the docs folder were removed, and the README no longer references any image

### v1.4 · Chinese/English switchable edition (2026-10-12)

- Added the Chinese/English switchable edition. A globe icon in the top-right of the home page opens language settings, allowing instant switching among Follow System / Chinese / English without reinstalling the app
- UI text uses the Chinese source string as the key: English translations live in en.lproj/Localizable.strings, and Chinese uses the identity map in zh-Hans.lproj, falling back to the original string when English is unavailable
- Language switching is managed by the LanguageManager singleton and written to UserDefaults; switching increments a token so the home page rebuilds the whole view tree via `.id()`, and every `L()` re-reads on the spot
- The bilingual edition display name is PluckBuddy and its Bundle ID is com.zehuiwu.pluckbuddy.bilingual, coexisting with the Chinese edition 弹拨搭子 and the international edition PluckBuddy — all three can be installed on one iPhone

### v2.0 · Unified bilingual edition (2026-10-17)

- The bilingual edition becomes the single maintained line as PluckBuddy 2.0. The Chinese edition and the English-only edition stop here and are archived, with their READMEs pointing to this repository
- The commit history is grafted onto the Chinese edition, so this repository carries the whole trajectory from the first runnable build in late September to today in one continuous timeline
- English mode leads the README and the full Chinese edition follows; both cover the same sections, and the English logo and app icon follow the interface language

### v2.1 · Technique Coach expansion (2026-10-21)

- The Fingering Coach gains a piece library with cultural notes, so practice can follow real repertoire with background context
- Each analysis session now produces an evaluation report summarizing the detected technique and the scored dimensions

### v2.2 · Reporting polish, a third language, and hand-side awareness (2026-10-22)

- Coach report visual polish: an emotional header line, brighter artwork and a shorter intro for an at-a-glance read
- Added Traditional Chinese (繁體中文) as a third interface language; the existing "中文" option is renamed "简体中文"
- Vision now detects both hands and tags left/right chirality, and technique classification is driven by the right hand — the foundation for the Vision-based classifier

### v2.3 · Tuner feedback and live roll detection (2026-10-26)

- The Tuner shows live pitch feedback for all four Pipa strings with correct string names
- Roll and tremolo detection fixed so speed and evenness metrics update live instead of freezing on the first reading
- Roll-uniformity scoring refined with an energy-flux onset detector; flower (轮指花开) and practice UI prompts fixed

### v2.4 · Vision-led classification and scoring refinements (2026-10-27)

- Technique classification now runs entirely on the Vision hand landmarks; the audio gate only decides whether a score is shown, not which technique is recognized. A windowed majority-vote debounce keeps the on-screen label stable instead of flickering between frames
- All four evaluation dimensions — hand shape, tiger-mouth angle, rhythm and wrist position — are now scored for every technique. Previously each technique reported only a subset, so the fixed score panel always showed one dimension as zero; tiger-mouth angle is computed from hand pose for all techniques and hand shape was added to tremolo
- The Fingering Coach now shows an alert when analysis stops without enough Pipa-sound evidence, instead of silently leaving the report blank
- The start/stop analysis button was moved up from the bottom edge, clear of the home indicator, so it is easier to tap

### v2.5 · Technique visualizations, practice companions and stability (2026-10-27)

- Sweep detection rewritten with a physically meaningful direction cue: the spectral centroid trend (via an FFT) now tells an up-sweep from a down-sweep, instead of comparing raw peak levels which had no physical meaning; sweep strength is normalized from each note's peak amplitude, and the direction-balance metric is corrected so a balanced session can actually reach 100%
- Tremolo Bloom (轮指花开) reworked: petals now grow in stages with a breathing pause between stages, fully bloomed flowers close petal by petal, reaching the speed target turns the bloom gold, and sustained excellent runs accumulate extra layers (重瓣); the notes-per-petal threshold was widened from 5 to 14 so the bloom no longer triggers too eagerly
- Metronome gains a Mute sound option (red/green light only, no tick) and the BPM ceiling was raised to 416 to cover fast tremolo practice
- Pluck (弹挑) stability measurement tightened: onset timing now locates the true attack inside each 64 ms buffer with a peak-search, and the jitter curve was relaxed (noise floor 0.006, coefficient halved) so a steady metronome run scores in a realistic 70–90% range instead of ~50%
- Pluck session summary now reports the whole-session average stability instead of the last instantaneous reading
- Roll (滚指) uniformity scoring refined with a median + MAD tolerance that drops outlier intervals, stabilizing the evenness score
- The three interface languages and the unit tests were updated to match the new keys (Mute, Range, Stability)

### v2.6 · Coaching score reliability fixes (2026-10-28)

- The Fingering Coach's evaluation report was scoring far lower than the actual playing on a normal session. The whole scoring chain was reviewed and the structural flaws were fixed rather than the thresholds loosened:
  - The rhythm dimension no longer collapses to zero when fewer than 4 onsets are detected; short sessions now get a conservative floor score instead of losing the whole 25% weight
  - Playing-stability now averages only the sub-metrics that actually have data, instead of averaging five items and scoring a hard zero for any missing one, so a missing pitch or hand-shape sample no longer drags the whole dimension down
  - Dynamic-stability was computed on per-frame RMS, whose natural pluck-decay sawtooth makes the coefficient of variation explode to zero; it now measures the coefficient of variation across the peak envelope of each plucked note
  - Timbre-stability's zero-crossing-rate series now excludes silent frames, removing the huge deviation between silent and voiced frames
  - Pluck / tremolo rhythm scoring had a unit mismatch: a fingertip displacement value was compared against a frequency (Hz) range, so it always fell into the "too slow" branch; the scoring now maps displacement magnitude to motion intensity correctly
  - On-device logging of the real tiger-mouth angle and wrist-speed distributions was added, to calibrate the remaining hand-shape thresholds with first-hand measurements before changing them

### v2.7 · Sweep direction fix, gradient bloom and live roll metrics (2026-10-29)

- Sweep direction detection rewritten to estimate the onset pitch by autocorrelation instead of the old FFT spectral-centroid trend. The previous FFT path was producing a corrupted spectrum, so direction was effectively random; the onset detector reads the fundamental of the first struck string (缠弦 ≈ 220 Hz against 子弦 ≈ 440 Hz) and separates down-sweep from up-sweep cleanly, for both sequential sweeps and same-fret four-note sweeps
- Sweep direction-balance metric corrected so it neither saturates at 100% nor collapses toward zero; it now reflects the true alternation quality of the whole session
- Tremolo Bloom (轮指花开) recolored from a fixed gold-at-target to a vibrancy gradient: the better the run, the more vivid the petals, while sustained excellent runs still accumulate extra layers (重瓣)
- Roll (轮指) uniformity now refreshes live every 5 seconds while practicing, instead of only when the session stops, so learners can watch evenness improve in real time

### v2.8 · History order and encouraging coach score (2026-10-29)

- The "My Scores · History" tab now lists coach evaluation reports (评价报告) above game scores (游戏得分), so the report a learner just generated sits at the top of the history instead of below the practice sessions
- Added a "游戏得分" heading (Game Scores) as a localization key across English / Simplified / Traditional Chinese so the two history groups read clearly
- The coach evaluation report uses an encouraging score curve: because a report is only generated after the on-device Pipa-sound gate confirms a Pipa is being played, any real score below 85 is remapped into a 87–95 band (monotonic, so weaker playing still reads lower but always stays above 85 — it never pins every practice at exactly 85), while real scores of 85 and above keep their natural value up to 100. The detailed sub-metrics keep showing real numbers so the feedback stays honest

### v2.9 · Sustained-sound report gate and duration-tiered scoring (2026-10-29)

- The coach evaluation report now generates only after **sustained** Pipa sound is detected, not merely after enough cumulative active frames and onsets. A continuity check requires at least one continuous active run of 0.75 s, a cumulative sounding time of at least max(1.5 s, 2× the longest run), three or more onsets, and a richness check (clear pitch detected or enough video hand-shape frames). This closes the false-report hole where knocking on a desk plus ambient noise could accumulate frames and onsets and still produce a high-scoring report
- The old gate used "longest continuous run ÷ total recording ≥ 25%" as the sounding criterion, which wrongly killed slow-tempo pieces that contain several seconds of rest. The new gate keys off cumulative sounding time instead, so rests never count against you and a normally-played adagio is no longer misjudged as "not playing"
- Overall score now follows a duration-tier model instead of a flat remap: it starts at 85.1, steps into the 90 band after 1 minute of practice, 92 after 2, 95 after 3, the 97+ "near-perfect" band after 5, and caps at 99.5 at 10 minutes. Until the next milestone is reached the score cannot cross it, so short sessions simply cannot reach the top
- Within a tier, the exact score is set by real performance plus a per-report random baseline shared across the overall and all four dimension scores, with a small independent perturbation per dimension. This keeps every practice's score different yet internally consistent (no "overall 95 but all four dimensions 85")

### v3.0 · A virtual Pipa, sounded from measured recordings (2026-11-19)

- The Fingering Coach can now be used with no instrument in hand. A virtual Pipa is drawn on screen and played from the camera: the left hand picks the string and the fret, the right hand plucks or sweeps, and the sound is rendered on the device with no audio file and no network. The goal is that a learner can rehearse fingering anywhere, and that a demonstration needs nothing but the phone
- The voice behind it is a modal model fitted to recordings of my own Pipa rather than a physical model. Each of the four open strings carries dozens of partials with their own fast and slow decay, split pairs that produce the beating, a stereo gain and phase per partial, and a residual layer holding whatever the partials cannot explain. Cross-string couplings were measured from the same takes
- The Karplus–Strong waveguide is still in the app and remains the fallback if the model resource cannot be loaded, so the instrument never goes silent because of a missing file
- The same voice drives the Pluck Run demo page, which previously played a hand-written sum of three sine waves
- Debug builds now optimise like Release. An unoptimised synthesis loop overran the audio buffer deadline on a real device and the app went quiet after a few plucks; the measured model has more partials than the waveguide, so the setting is not optional here
- The Fingering Coach gained two entries that need no instrument at all. **Reference Demo** plays a bundled clip of a correct hand posture through the same Vision pipeline the live coach runs, so the 21 landmarks, the tiger-mouth angle and the coaching feedback can all be watched with no camera and no Pipa. **Play** opens the virtual instrument itself. Both are fully offline; frames are decoded from the bundle, nothing leaves the device
- Pluck Run was split into two modes over one unchanged layout. **Watch demo** loops a scripted performance with no microphone, for showing the idea. **Play along** puts four on-screen strings under your right hand, and every pluck moves the runner one step. Only the lower half of the screen changes when you switch, so the track and the runner stay put

### v3.1 · Fingering on the fingertip, and open strings when nothing is held (2026-11-19)

- The left hand used to be read at the wrist, on the assumption that the wrist sits over the note being stopped. On a neck this narrow the wrist is a whole hand behind the fingertip, so the same posture produced a note two or three positions lower, and rotating the wrist moved the marker sideways. The reading now comes from the index fingertip, falling back to the DIP and PIP joints behind it so a soft-edged or self-occluded tip does not freeze the note
- Plucking with no fret held used to be silent. The right fingertip now sounds the open string it is over. The selection also releases: half a second without the left fingertip on the neck returns the instrument to open strings, instead of the old behaviour where one touch of the neck held that note until the page was closed
- When a hand leaves the frame, Vision still reports all 21 points and places the wrist on the far side of the palm, so five long bones fan out of empty space. Wrist points that contradict the palm shape — the distances to the four knuckles spreading far wider than a real hand's — are dropped from the overlay. This is drawing only, never the sounding path: a wrong guess there would cost a real pluck or a real sweep
- A finger that disappears for a frame no longer keeps its old position, which used to make the jump back register as a pluck and fire a note that was never played

### v3.2 · Telling a pluck apart from a hand movement (2026-11-19)

- Waving the right hand over the neck used to fire notes, because any fingertip travelling far enough in one frame counted as a pluck. Two conditions now separate the two: the travel has to be across the string rather than along it, and the arm must not be carrying the hand at that moment — wrist motion above a threshold suppresses fingertip flicks for that frame, since that is a sweep in progress. A pluck is a finger action; a sweep is an arm action
- Velocity now follows how far the fingertip travelled in one frame: 0.45 at the flick threshold, 1.0 at 0.18 of the screen width, linear in between. A gentle stroke is quiet and a hard one loud. The fitted model was measured at a single force, so this is loudness dynamics only — it cannot make the tone brighter with force
- Both axes are brought onto the frame width's ruler before anything is compared. Vision normalises x by the frame width and y by its height, so on a 16:9 portrait frame a diagonal stroke would otherwise read as twice as steep as it really is

### v3.3 · The thumb's 挑, and strokes that only count one way (2026-11-19)

- The thumb never made a sound. Vision does not drop a joint it cannot see: it returns it at confidence 0, at a guessed position that does not move with the finger. With the thumb tucked alongside the index, the way it sits in 弹挑, its tip is the least visible point on the hand, so the pluck was being read off a fabricated dot that never travelled. Each finger is now read through the first joint Vision is actually confident about — the thumb through its tip, IP or MP joint, the others through tip or DIP — and a frame where the joint changes is discarded rather than read as a jump between two points two centimetres apart
- One travel threshold could not serve five fingers. The index swings from the knuckle while the thumb rolls from the base of the hand, and for the same stroke its tip covers a little over half the ground. Measured by the index's ruler a 挑 came in below the bar every time. Each finger now has its own threshold, and velocity is scaled from that finger's threshold rather than from a shared one
- The string played is now the line the stroke crossed, not the band the fingertip happened to end in. A 挑 finishes barely past the string it plucked, which used to round into the neighbouring band and then be dropped for disagreeing with the left hand; a stroke finishing outside the neck produced no string at all. When a stroke is too short or too square-on to cross a line on screen, the nearest string to the middle of the stroke is credited instead, and only for a full, clearly horizontal stroke
- Strokes count one way only, the way the instrument works: the four fingers pluck from screen right to left, the thumb from left to right, and the way back is silent. Before, one stroke sounded twice — once going out, once coming back — and a hand curling inward played notes it never struck

### v3.4 · One note per stroke on the open-string pad (2026-11-23)

- On the tablet, almost every stroke on the Pluck Run play pad sounded twice. Landing on a string fired a note, and crossing that same string fired it again a fraction of a second later. A finger resting on a real string does not sound it; the crossing does. Landing now only records where the stroke began and lights the string under it. A note is fired by crossing a string, and if a whole stroke never crossed one, lifting the finger supplies a single tap note
- Crossing used to be decided by looking up the string's x at the stroke's end, then checking whether that x fell inside the stroke's horizontal span, with a small margin at both ends. On a slanted string a long stroke was several pixels off, and the margin swallowed a slow stroke that moved less than one margin per frame while skipping strings on a fast one. Each frame now solves for where the segment actually meets each slanted string, for t in (0, 1], so a string sounds exactly on the frame it is crossed however fast or slow the finger moves
- The "finger is still" threshold is now measured in screen points instead of source-image pixels. The image is scaled up on the pad, so a threshold in source pixels swallowed slow strokes — around 80 pt/s produced no sound at all. 0.2 screen points filters only repeated reports of the same position

## Known Limitations / To Be Improved

- Classifier precision is still limited by the training data distribution. If the real-device console shows `rms > 0.05` but `pipa < 0.3`, the model's discriminative power is insufficient for the current microphone sound quality, and it needs to be retrained with the Create ML Sound Analysis template (≥ 30 clips of 16 kHz audio per class; a clearly better model can usually be produced within 30 minutes)
- The provisioning profile of a free Apple ID expires after 7 days; you need to reconnect to Xcode and re-sign
- Camera / microphone features require a real device and cannot be demoed on the Simulator
- The Social Hub is an offline demo version; leaderboard / achievements / friend PK data is stored in local CoreData

## License

Source code of a personal project; discussion and learning welcome.

---

# 虚拟琵琶 — 手上没有琴也能练

一款让人手上没有琴也能练琵琶指法的 iOS 应用。摄像头对着屏幕上画出的虚拟琵琶读双手：左手定弦与定品，右手弹与扫，声音是对自己那把琵琶的录音拟合出的模态模型，在设备上实时渲染。调音、指法教练、三个陪练与节拍器都在这版里，与双语版同源，在此之上多了这台虚拟琴。

> 个人项目 · 源于自己的习琴需要,在长期练习中持续打磨
>
> 开发者:吴泽荟
> 学校:武汉康礼高级中学

## 获奖与展示

- **一等奖**:中国高校计算机大赛 · 2026 移动应用创新赛(启航赛道 · 中小学组)。
- 作为中小学生唯一代表,在大会现场演示了本项目。
- 大会现场照片、演示视频与英文版功能介绍已归档在 [PluckBuddy-Bilingual 的 `docs/CCCC-MAIC/`](https://github.com/ZehuiWU2009/PluckBuddy-Bilingual/tree/main/docs/CCCC-MAIC/)。

## 上架与报道

- **已上线 App Store**:[PluckBuddy](https://apps.apple.com/cn/app/pluckbuddy/id6824425608) 现已开放下载。
- **Apple 专访**:Apple 对开发者吴泽荟做了专访,并在小红书 @Apple 官方账号发布了 [「移动应用创新赛，听听她的好点子」](https://www.xiaohongshu.com/discovery/item/6af032540000000015009ff2?xsec_token=ABGYVgZb2HZKZH8hneihDgHhve3lu9lVEoICv6WdHYOwk=&xsec_source=pc_share)。

## 本项目的技术贡献

项目在以下七个方向做了技术创新与工程取舍。

### 贡献 1 · 声音来自实测、而非物理建模的虚拟琵琶

虚拟琴不是按物理规律算出来的，它回放的是这把琴真实做过的动作：四根空弦各录一遍，再把每一遍拆成构成它的那些模态。波导能告诉你一根弦一般怎么振动，只有测量能告诉你**这把**琵琶是什么声音。

- **259 个模态，逐个量出**：子弦 44 个，其余依次 59、66，缠弦 90 个。每个模态带着自己相对基频的频率比、振幅、左右声道各自的增益与相位，以及两段式衰减——一段快、一段慢——因为真实的泛音不会以单一速率落下。缠弦上最慢的衰减是 9.5 秒，子弦最高那些泛音只有 0.04 秒，这就是低音弦在别的音都走掉之后还在响的原因
- **拍频留着，没有平均掉**：259 个模态里有 19 个不是单根正弦，而是一对相差不到 1 赫兹、相位固定的分音。长音那层微微的晃动就来自它们；把一对并成一个平均频率的正弦，声音立刻是死的，耳朵第一下就听得出来
- **分音解释不掉的那部分单独成层**：指甲的噪声、琴身的闷响、邻弦的余韵，按弦各存一层 1.5 秒的立体声残余，与模态一起渲染。让一串正弦去还原瞬态，正是合成乐器听着像合成乐器的原因
- **跨弦耦合也从同一批录音里量**：拨一根弦，另外三根仍会通过琴码被带起来，耦合量是量出来的，不是估的
- **没有一处靠信任**：每根弦的验收渲染与模型输出逐项比对，`provenance.json` 里记录的最坏截断误差是 2e-10，所以哪怕重构 259 个模态也不会悄悄改掉声音。资源缺失时回落到 Karplus–Strong 波导，不会没声音

### 贡献 2 · 音视频多模态融合检测指法

弹拨搭子把 Vision 手部关键点、FFT 频谱与 CoreML 分类器三路信号融合，共同判定弹挑、轮指、扫弦、长音四类指法。

- **音频侧**：Accelerate 框架做 4096 点 FFT，实时测算音高与节奏；同时把 48 kHz 硬件缓冲线性插值降采样到 16 kHz，喂给 CoreML 分类器做"是不是琵琶"的判门
- **视频侧**：Vision 追踪手部 21 个关键点，经卡尔曼滤波平滑后计算虎口角度、手腕高度，作为技法判定的几何特征
- **融合策略**：音频判别"是不是琵琶声"（排除人声 / 环境噪音）；视频判别"手型对不对"；两个都过才进入技法分类，避免单一模态误判

### 贡献 3 · 端侧自训练 CoreML 琵琶声分类器

内置自训练的四分类模型 `PipaSoundClassifier.mlmodel`，输入是 Float32 的 `audioSamples`，长度 15600 帧，约合 16 kHz 采样率下 0.975 秒的窗口，输出四类概率：

| 类别                 | 含义   |
| ------------------ | ---- |
| `pipa`             | 琵琶声  |
| `other_instrument` | 其它乐器 |
| `speech`           | 人声   |
| `background`       | 背景噪声 |

- **端侧推理**：`MLModel.prediction` 跑在 iPhone 神经引擎上，单次推理不到 80 ms
- **零网络依赖**：整个推理在本地完成，不上传任何音频片段
- **工程层精度优化**：不动模型本身，改用阈值 0.35 加 2 帧滑动平均，再加一道能量门控，低 RMS 的安静帧直接判 background，推理步长也从 15600 帧改成 8000 帧形成重叠窗口
- **训练数据已公开**：训练该模型所用的四分类录音已作为独立的数据资产发布——见下面的贡献 4

### 贡献 4 · 作为可复用数据资产公开的琵琶声音数据集

上面那个分类器有多准，取决于它背后的音频。因此这批音频没有留在任何 App 工程里，而是只放在独立仓库 [github.com/ZehuiWU2009/PipaSoundClassifierDataset](https://github.com/ZehuiWU2009/PipaSoundClassifierDataset)，以 CC BY 4.0 发布，887 MB 真实音频在那里走 Git LFS 跟踪。PluckBuddy-Bilingual 和 PluckBuddy-VirtualPipa 两个工程共用这一份数据集来训练声音判门，它是共享资产，不专属于某一个 App。

- **收录了什么**：共 43 段、约 887 MB，按判门需要的四个类别分开——`pipa/` 7 段我自己弹的琵琶（覆盖不同指法）、`other_instrument/` 24 段我自己会演奏的乐器加三段 AI 生成的古筝、`speech/` 6 段我自己的声音、`background/` 6 段日常环境噪音
- **每一段都可公开**：要么是本人录制，要么是家人录制并已获授权，要么是 AI 生成，没有转引他人录音
- **采样流程完整记录**：每段录音都混为单声道，线性插值降采样到 16 kHz，切成 15,600 个采样点、约 0.975 秒的窗口并以 50% 重叠推进，再把原始波形送进分类器——与已发布模型接受的窗口一致
- **来源可见**：其中 25 段在音频之外还带 640x480 视频轨，以 `.mp4` 格式通过 Git LFS 存放，让人能确认当时到底弹了什么；训练只用音频
- **为什么算数据资产而不是脚注**：真正让判门有用的，是那些负样本；而负样本恰恰是最难收集的。把它公开，意味着别人可以在同样的起点上重训这道判门，而不必自己猜"非琵琶"该是什么声音

### 贡献 5 · 4096 点 FFT + 卡尔曼滤波的实时算法

- **FFT 频谱分析**：`DSPFeatureExtractor.swift` 用 `vDSP_fft_zrip`（Accelerate 加速）做 4096 点 FFT，计算 RMS、谐波比、频谱质心、过零率等指标，作为音高检测和分类器输入特征
- **卡尔曼滤波平滑**：`HandPoseExtractor` 拿到的 21 个关键点每帧都有抖动，直接用会引入噪声；经卡尔曼滤波平滑后，再算虎口角度、手腕高度，能稳定输出虎口张开度数
- **并行处理**：麦克风 4096 帧缓冲和摄像头帧在两条独立线程上采集，互不阻塞；CoreML 推理在 `inferenceQueue` 串行队列上跑，不抢音频主线程

### 贡献 6 · 统一音频管线 + 模型门控架构

iOS 上多个模块都想用麦克风，但 AVAudioEngine 的 tap 只能被一个处理器装上——多模块并发会直接冲突。弹拨搭子的解法：

```
┌──────────────────────────────────────────────────┐
│ AudioManager (单例)                              │
│ ├── AVAudioEngine                                │
│ ├── 4096 帧 tap                                 │
│ └── startListening { buffer in                    │
│     ├─→ 调音: PipaSoundGate (判门) + PitchDetector │
│     ├─→ 弹挑跑步: RhythmDetector                  │
│     ├─→ 轮指花开: RollDetector                    │
│     └─→ 扫弦水波: SweepDetector                  │
│    }                                              │
└──────────────────────────────────────────────────┘
```

- 单一 AVAudioEngine、单一 tap，所有需要音频的模块共享一份缓冲回调
- `PipaSoundGate` 独立加载 `PipaSoundClassifier.mlmodel`，**不接管 AVAudioEngine tap**——它只接管"降采样 + 模型推理"，避免和指法教练的 Engine 抢资源

### 贡献 7 · 全离线端侧五层架构

详细架构图见下一节《系统架构》。核心创新点：

- 五层自下而上依次是音视频采集、信号处理、模型推理、指标评估、交互呈现，每层职责单一、彼此解耦
- 采集、特征提取、推理、评估各跑在独立的队列上，主线程只负责刷新 UI
- 练习录像、评分、排行榜全部写进本地 CoreData，不联网上传，也不从网络下载

## 系统架构

采用端侧全离线五层架构,从麦克风 / 摄像头原始数据到 UI 反馈全部在 iPhone 上完成,无任何网络依赖。

各层的模块映射关系如下。

```mermaid
flowchart TB
    subgraph L1 ["第 1 层 · 音视频采集"]
        A1["AVAudioEngine 麦克风 tap<br/>硬件 48 kHz, 4096 帧 / 帧"]
        A2["AVCaptureSession 摄像头<br/>Vision 手部 21 关键点"]
    end
    subgraph L2 ["第 2 层 · 信号处理"]
        B1["FFT 频谱 + 谐波比 + 频谱质心<br/>(DSPFeatureExtractor)"]
        B2["48 kHz → 16 kHz 线性插值降采样<br/>单声道混音"]
    end
    subgraph L3 ["第 3 层 · 模型推理 (CoreML)"]
        C1["PipaSoundClassifier<br/>四分类: 琵琶 / 其他乐器 / 人声 / 背景<br/>输入: 15600 帧 @ 16 kHz 滑动窗口"]
    end
    subgraph L4 ["第 4 层 · 指标评估"]
        D1["音高检测 (PitchDetector)"]
        D2["节拍 / 轮指 / 扫弦检测器"]
        D3["技法分类 (VisionTechniqueClassifier)<br/>弹挑 / 轮指 / 扫弦 / 长音 / 噪音<br/>分项指标由 TechniqueEvaluators 给出"]
    end
    subgraph L5 ["第 5 层 · 交互呈现"]
        E1["SwiftUI 视图层<br/>实时波形 + 评分卡片 + 量化指标"]
        E2["Lottie 动画<br/>跑道角色 / 花瓣绽放 / 水波纹"]
    end

    L1 --> L2 --> L3 --> L4 --> L5

    %% 横向细节
    A1 --> B2 --> C1 --> D1
    A2 --> D3
    D1 --> E1
    D2 --> E2
    D3 --> E1
```

**五层职责说明**

| 层         | 输入              | 输出                  | 关键文件                                                                                                                |
| --------- | --------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------- |
| 1 · 音视频采集 | 用户在 iPhone 前的演奏 | 原始 PCM 流 / 摄像头帧     | `AudioManager.swift`、`VideoCaptureManager.swift`、`CameraManager.swift`                                             |
| 2 · 信号处理  | 原始 PCM          | 频谱特征 / 16 kHz 归一化样本 | `DSPFeatureExtractor.swift`、`PipaSoundGate.swift`(降采样)                                                              |
| 3 · 模型推理  | 15600 帧归一化样本    | 4 类别概率分布            | `PipaSoundClassifier.mlmodel`、`PipaSoundGate.swift`(推理)                                                             |
| 4 · 指标评估  | 频谱特征 + 视频关键点    | 音高 / 节拍 / 技法判定      | `PitchDetector.swift`、`RhythmDetector.swift`、`RollDetector.swift`、`SweepDetector.swift`、`TechniqueEvaluators.swift`、`VisionTechniqueClassifier.swift`、`HandPoseAnalyzer.swift` |
| 5 · 交互呈现  | 指标数据            | 用户可见的 UI 与动画        | 22 个 `*View.swift` 文件 + `Animations/*.json` + `LottieRunnerView.swift`                                              |

**还有一条并行的支路**

上面五层讲的是演奏**怎么被评判**。虚拟琵琶负责发声，走的是另一条线：摄像头帧 → `HandPoseExtractor` → `VirtualPipaController` → `VirtualPipaEngine` → `VirtualPipaCore`。它和第 1 层共用视频采集与 21 个关键点，但与第 2 到 4 层无关——虚拟琴从不打开麦克风，一次拨弦是一次手部动作而不是一段声音，手指和弦之间也没有分类器。手势的全部判断都在 `VirtualPipaController`：左手在哪根弦、按第几品、一笔指尖动作是拨弦还是手臂在带手。指法教练里的指法演示方向相反：从包内解出的视频帧喂进同一套 `HandPoseExtractor`，所以在没有摄像头、没有琴的情况下也能看到关键点、虎口角度与教练反馈。

**为什么这样分**

- 第 1 层专注采集，所有输入输出集中在一处，避免多个模块争抢 AVAudioEngine 的 tap
- 第 2 层做格式归一，把硬件的 48 kHz 转成模型需要的 16 kHz 15600 帧窗口，下游可以无差别地喂数据
- 第 3 层跑 CoreML 推理，单次不到 80 ms，全程离线
- 第 4 层是演奏领域的判定逻辑，5 个检测器各管一个维度，彼此独立可测
- 第 5 层只负责渲染，SwiftUI 订阅 ViewModel 的 Published 状态，不掺入计算

## 核心功能

| 模块         | 说明                                                                          |
| ---------- | --------------------------------------------------------------------------- |
| **智能指法教练** | 摄像头实时识别左右手指型(Vision 框架),匹配琵琶核心 5 种技法(弹挑/轮指/扫弦/长音/噪音),给出连续帧稳定的技法评分与核心要求轮播。另有无需琵琶的两个入口:指法演示播一段内置视频并跑同一套 Vision 管线,演奏入口直接用虚拟琵琶 |
| **虚拟琵琶**   | 手上没有琴也能练。屏幕上画出虚拟琵琶,由摄像头驱动:左手定弦与品,右手弹或扫。发声是对真琵琶四根空弦录音拟合出的模态模型,在设备上离线渲染 |
| **智能调音**   | 麦克风采集琵琶空弦音,自研 FFT 算法给出当前音高与十二平均律标准音的 cents 偏差;接 CoreML 分类器做「先判琵琶声 → 再判音高」门控 |
| **弹挑跑步**   | 节拍跑道游戏化陪练,分两个模式。演示模式播一段脚本化的演奏,不用麦克风;弹挑模式给出一块四根弦的琴面,每拨一下就前进一步。两者都统计节拍稳定性 BPM 与总分 |
| **轮指花开**   | 轮指训练花朵生长可视化。检测连续快速拨弦的均匀度,完成一轮后花瓣绽放                                          |
| **扫弦水波**   | 扫弦训练水波纹可视化。区分上扫/下扫,生成对应方向的水波纹动画                                             |
| **节拍器**    | 独立可调 BPM 节拍器,适配不同练习场景                                                       |
| **社交广场**   | 离线排行榜 / 成就 / 好友 PK(本地持久化,演示用)                                               |
| **欢迎界面**   | 米白底 + Logo + "今天也来练 5 分钟吧" + 3 秒倒计时自动退出 + 右上角"跳过"                           |

## 技术栈

- 开发语言是 Swift 6，界面用 SwiftUI，状态绑定用 Combine，并发按 Swift Concurrency 的严格模式编写
- 运行平台为 iOS 17.6 及以上的 arm64 真机，摄像头与麦克风功能必须在真机上演示
- 算法侧用 Accelerate 框架的 vDSP 做 FFT，AVAudioEngine 负责麦克风采集，Vision 负责手部关键点提取
- 声学模型是自训练的 CoreML 四分类模型 PipaSoundClassifier，区分琵琶、其它乐器、人声与背景噪声，全程离线推理
- 虚拟琵琶的声音是对自己那把琵琶的录音拟合出的模态模型：每根弦各有自己的分音、各自的衰减与立体声增益相位，再加一层残余，全部在设备上渲染；Karplus–Strong 波导留在 App 里作回退
- 音频采集由自写的 AudioManager 统一装 tap，每缓冲 4096 帧，再用线性插值把硬件的 48 kHz 降到 16 kHz
- 手型由 HandPoseExtractor 提取左右手各 21 个关键点，再算出虎口角度与手腕高度
- Lottie 负责扫弦水波与跑道角色动画，CoreData 负责练习记录、排行榜与成就的本地持久化

## 项目结构

```
PluckBuddy/
├── PluckBuddy.xcodeproj/       # Xcode 工程
├── PluckBuddy/                 # 主 target 源码
│   ├── PluckBuddyApp.swift               # App 入口(欢迎/首页切换)
│   ├── ContentView.swift                 # 根容器:先欢迎页,再首页
│   ├── WelcomeView.swift                 # 启动欢迎页(3 秒倒计时淡出)
│   ├── HomeView.swift                    # 主页(七大模块入口)
│   ├── MainMenuExample.swift             # 首页背后的菜单卡片版式
│   ├── Localization.swift                # L() 取值、LanguageManager、Bundle 切换
│   ├── LanguageSettingView.swift         # 跟随系统 / 简体中文 / 繁體中文 / English
│   ├── en.lproj/                         # 英文 Localizable.strings
│   ├── zh-Hans.lproj/                    # 简体中文表(恒等映射,key 就是中文原文)
│   ├── zh-Hant.lproj/                    # 繁体中文表
│   ├── TechniqueCoachView.swift          # 智能指法教练界面
│   ├── TechniqueCoachViewModel.swift     # 它的状态:帧、评分与报告门控
│   ├── TechniqueType.swift               # 五种技法及其命名
│   ├── TechniqueEvaluators.swift         # 按技法分项评估
│   ├── TechniqueRequirementsManager.swift # 核心要求轮播
│   ├── VisionTechniqueClassifier.swift   # 关键点转技法,带众数去抖
│   ├── HandPoseExtractor.swift           # Vision 手型提取,每只手 21 个关键点
│   ├── HandPoseAnalyzer.swift            # 平滑、虎口角度、假腕点过滤
│   ├── CameraPreviewView.swift           # 摄像头预览层与关键点叠加
│   ├── VideoCaptureManager.swift         # 为教练管线输出视频帧
│   ├── VideoRecorder.swift               # 录制随报告保存的练习片段
│   ├── FingeringDemoView.swift           # 指法演示:内置视频跑同一套 Vision 管线
│   ├── CoachReport.swift                 # 报告模型、曲库与会话音频分析
│   ├── CoachReportStore.swift            # 报告的本地存档
│   ├── CoachReportView.swift             # 报告页
│   ├── PracticePieceCulture.swift        # 每首练习曲的文化背景
│   ├── PracticeSession.swift             # 一次练习的会话记录
│   ├── PracticeDataManager.swift         # 每日统计与历史
│   ├── TunerView.swift                   # 智能调音界面
│   ├── TunerViewModel.swift              # 音高、音分偏差与弦名
│   ├── PipaSoundGate.swift               # 调音专用琵琶声判门(独立加载模型,不与指法教练抢 AVAudioEngine 的 tap)
│   ├── PipaSoundClassifier.mlmodel       # 端侧四分类 CoreML 模型
│   ├── RunningPracticeView.swift         # 弹挑跑步界面:演示与弹挑两个模式
│   ├── RunningViewModel.swift            # 弹挑跑步 ViewModel
│   ├── RunningDemoViews.swift            # 小人、跑道与脚本化演示视频
│   ├── PipaOpenStringsPad.swift          # 弹挑跑步两个模式共用的四弦琴面
│   ├── LottieRunnerView.swift            # Lottie 驱动的小人动画
│   ├── FlowerPracticeView.swift          # 轮指花开 UI
│   ├── FlowerViewModel.swift             # 轮指花开 ViewModel
│   ├── FlowerSettingsSheet.swift         # 轮指花开设置
│   ├── WavePracticeView.swift            # 扫弦水波 UI
│   ├── WaveViewModel.swift               # 扫弦水波 ViewModel
│   ├── WaveSettingsSheet.swift           # 扫弦水波设置
│   ├── MetronomeView.swift               # 节拍器 UI
│   ├── MetronomeManager.swift            # 节拍器调度
│   ├── VirtualPipaPlayView.swift         # 虚拟琴界面、琴颈绘制与手部叠加层
│   ├── CameraManager.swift               # 虚拟琴的摄像头采集
│   ├── VirtualPipaController.swift       # 把双手动作翻译成弦、品与拨弦事件
│   ├── VirtualPipaEngine.swift           # 虚拟琴的音频会话、源节点与弹/扫入口
│   ├── VirtualPipaCore/                  # 发声内核:实测模态模型、波导回退、定弦表
│   │   ├── PipaKitModel.swift            # 读取并校验 model.json、四组预设与来源记录
│   │   ├── PipaKitVoice.swift            # 一个发声的音:该弦全部泛音,各带快慢衰减、分裂对与残余层
│   │   ├── PipaKitSynth.swift            # 四弦声部池、跨弦耦合与立体声混音
│   │   ├── PipaSoundEngine.swift         # 持有源节点输出的薄封装
│   │   ├── PipaSynth.swift               # 作为回退保留的 Karplus–Strong 四弦引擎
│   │   ├── PipaString.swift              # 单根波导:延迟线、环路滤波与激励
│   │   ├── PipaBody.swift                # 琴体共振:一段低频搁架加五个峰值段
│   │   ├── PipaTuning.swift              # 空弦 MIDI 音高、品位表与音高换算
│   │   └── PipaAudioCore.swift           # 实时循环与无锁命令队列
│   ├── KitResources/                     # 四根空弦的拟合模型(model.json、来源记录、四层残余)
│   ├── AudioManager.swift                # 统一音频采集
│   ├── DSPFeatureExtractor.swift         # 自研 FFT 频谱特征
│   ├── PitchDetector.swift               # 音高检测
│   ├── PitchDetectorTests.swift          # 音高检测的单元测试
│   ├── RhythmDetector.swift              # 弹挑节拍检测
│   ├── RollDetector.swift                # 轮指检测
│   ├── SweepDetector.swift               # 扫弦检测
│   ├── SocialSquareView.swift            # 社交广场
│   ├── FriendPKView.swift                # 好友 PK
│   ├── AchievementView.swift             # 成就
│   ├── RankingListView.swift             # 离线排行榜
│   ├── SocialModels.swift                # 排行、成就、好友模型与示例数据
│   ├── ResultView.swift                  # 成绩与报告历史
│   ├── ScrollingTextView.swift           # 滚动横幅文字
│   ├── EnhancedScrollingBanner.swift     # 横幅组件
│   ├── ScrollingTextTestView.swift       # 横幅预览页
│   ├── Persistence.swift                 # CoreData 持久化
│   ├── PluckBuddy.xcdatamodeld/          # CoreData 模型
│   ├── PrivacyInfo.xcprivacy             # 隐私清单
│   ├── Animations/                       # Lottie 动画 JSON
│   └── Assets.xcassets/                  # 资源(Logo 等)
└── PluckBuddyTests/            # 单元测试 target
```

## 运行方式

1. **Mac 上 Xcode 17+ 打开** `PluckBuddy.xcodeproj`
2. 左侧工程 → TARGETS `PluckBuddy` → **Signing & Capabilities**
   - **Team** 选你自己的 Apple ID(免费账号即可)
   - **Bundle Identifier** 改成你账号下未注册的(如 `com.你的名字.pluckbuddy`)
3. 连真机 → 顶部设备栏选 iPhone → `Cmd+R`
4. **真机系统要求**:iOS 17.6 或更高
5. **真机首次**:设置 → 隐私与安全性 → 开发者模式 → 打开并重启;跑起来弹「不受信任的开发者」时,设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID
6. **摄像头 / 麦克风模块**(指法教练 / 调音 / 三个陪练)**必须真机运行**,模拟器无摄像头/麦克风

免费 Apple ID 描述文件 7 天过期,到期需重连 Xcode 重新签名安装。

## 版本演进

v1.0 到 v1.3 是 2026 年 9 月底到 10 月初以中文版形态走完的四轮迭代,每一轮都由真机测试暴露的问题驱动。同期还从同一份代码并行做出一个全英文国际版。两个旧版本现已停止维护并归档,由本仓库统一继承,作为 PluckBuddy 2.0 继续演进。本仓库的 commit 历史自中文版嫁接而来,从 9 月底首个可运行版本到今天形成一条连续时间线。

### v1.0 · 首个完整版本(2026-09-29)

- 七大模块全部打通:智能指法教练、智能调音、弹挑跑步、轮指花开、扫弦水波、节拍器、社交广场
- 音视频双通道跑通,端侧 CoreML 四分类模型接入指法教练
- 52 个 Swift 文件,约 13,700 行

### v1.1 · 调音判门与分类器精度(2026-09-30)

- 调音模块接入端侧琵琶声判门,新增 `PipaSoundGate.swift`。它不接管 AVAudioEngine 的 tap,只负责降采样与模型推理,麦克风数据仍由 `AudioManager` 统一分发,避免与指法教练和三个陪练模块争抢音频资源
- 门控规则:最近 0.5 秒内判定为琵琶声才进入音高计算,其余帧显示「聆听中…等待琵琶声」
- 分类器精度做工程层优化。真机实测 pipa 概率多落在 0.3 到 0.7 区间,于是把判定阈值由 0.5 降到 0.35,滑动平均窗口由 3 帧改成 2 帧,推理前加一道能量门控,RMS 低于 0.01 的安静帧直接判为背景噪声,推理步长由 15600 帧改为 8000 帧形成约五成重叠窗口
- 欢迎页改为先淡出再移除,主界面同步淡入,并加 `isDismissing` 守卫,消除倒计时归零与点跳过按钮之间的竞态

### v1.2 · 手型指标与采样率口径(2026-10-01)

- 手部骨架由 6 点简化画法换成 21 点完整骨架。5 个指尖画彩色大圆,手腕画蓝色圆点,15 个中间关节画半透明白色小圆,再连出 5 条指骨线与 5 条掌线
- 手型评分项由手指角度换成虎口角度:以手腕为顶点,取拇指方向与食指方向的夹角。30 到 50 度判满分,过小提示拇指与食指靠得太近,过大提示虎口撑得太大
- 采样率口径统一到真机实测的 48 kHz。四个检测器与四个 ViewModel 的默认值由 44100 改为 48000,此前音高偏低约 1.5 个半音、节拍偏慢约 8.8% 的偏差一并消除。单元测试仍用自合成的 44100 信号,自洽不动
- 文档里的指尖角度口径同步改为虎口角度,保证评审对照代码时说法一致

### v1.3 · 真机警告清零与发布整理(2026-10-02)

- 真机构建的 13 条代码警告全部消除。8 处闭包捕获语义改为显式弱引用,页面销毁时直接退出启动流程;3 处计时器回调改为在主线程上读取被隔离的属性;2 处统计了却没参与判定的方向计数删除
- 中文版桌面显示名改为弹拨搭子,首页标题与麦克风权限说明同步更新。工程名、target 名与 Bundle ID 一律不变,两个版本可以共存安装
- 国际版 App 图标换成英文版设计,默认、深色、着色三种外观一起更新;中文版欢迎页改用中文版 logo
   - 仓库清理:移出架构图与 logo 图片、可编辑源图和文档目录,README 不再引用任何图片

### v1.4 · 中英双语可切换版(2026-10-12)

- 新增中英双语可切换版本。首页右上角地球图标进入语言设置，可在「跟随系统 / 中文 / English」之间即时切换，不用退出 App 重装
- 文案以中文原文为 key：英文译文集中在 en.lproj 下的 Localizable.strings，中文用 zh-Hans.lproj 的恒等映射表，取不到英文时回退为原文
- 语言切换由 LanguageManager 单例管理，选择写入 UserDefaults；切语言时递增 token，让首页以 .id() 重建整棵视图树，所有 L() 就地重新取值
- 双语版桌面显示名定为 PluckBuddy，Bundle ID 为 com.zehuiwu.pluckbuddy.bilingual，与中文版「弹拨搭子」、国际版 PluckBuddy 三个版本可共存安装

### v2.0 · 统一双语版(2026-10-17)

- 双语版成为唯一维护线，作为 PluckBuddy 2.0 继续演进。中文版与国际版到此停止维护并归档，各自 README 指向本仓库
- commit 历史嫁接自中文版，本仓库因此承载从 9 月底首个可运行版本到今天的一条连续时间线
- README 改为英文完整版在前、中文完整版在后，两版覆盖相同章节；欢迎页 logo 与桌面图标跟随界面语言切换

### v2.1 · 指法教练扩展(2026-10-21)

- 指法教练新增曲库并附文化背景注释，练习时可跟随真实曲目并了解其背景
- 每次分析结束生成评价报告，汇总识别到的技法与各项评分

### v2.2 · 报告打磨、第三语言与左右手感知(2026-10-22)

- 评价报告视觉打磨：情感化标题、更亮插画、更精简的引言，一眼就能读完
- 新增繁体中文(繁體中文)作为第三界面语言；原「中文」选项改名为「简体中文」
- Vision 现在能检测双手并标注左右手 chirality，技法判定交由右手驱动，为纯 Vision 分类器打下基础

### v2.3 · 调音实时反馈与轮指实时检测(2026-10-26)

- 调音器为四根琵琶弦提供实时音高反馈并显示正确弦名
- 修复轮指 / 吟揉检测，速度与均匀度指标实时更新，不再卡在第一帧
- 轮指均匀度评分改用能量通量起音检测细化；轮指花开与练习 UI 提示修复

### v2.4 · Vision 主导分类与评分打磨(2026-10-27)

- 技法分类完全交由 Vision 手部关键点判定，音频判门只决定展不展示分数，不再影响技法识别结果。新增基于最近若干帧的众数去抖，屏幕上的技法标签不再逐帧跳动
- 手型、虎口角度、节奏、手腕位置四个评分维度现在对每种技法都打分。此前每种技法只产出其中一部分，固定评分面板总有一项显示为零；虎口角度改为对全部技法由手姿统一计算，轮指也补上了手型维度
- 指法教练在停止分析但琵琶声证据不足时弹出提示，而不是默默留空报告
- 开始/停止分析按钮从屏幕底边上移，避开 Home 指示条，更好点按

### v2.5 · 技法可视化、陪练打磨与稳定性(2026-10-27)

- 扫弦判定重写，方向改用有物理意义的判据：用 FFT 频谱质心走向区分上扫与下扫，取代原来"比较原始峰值大小"这种没有物理含义的写法；扫弦力度按每次起音的峰值振幅做归一化，方向平衡公式也修正为均衡练习能真正拿到满分
- 轮指花开重做：花瓣分阶段生长、阶段之间留呼吸停顿，满花后花瓣依次收拢，达到速度目标转金色，连续优秀累积成重瓣；每瓣所需音符数从 5 放宽到 14，花开不再一碰就开
- 节拍器新增「静音」音色（只有红/绿灯、不响），BPM 上限提到 416，覆盖快速轮指练习
- 弹挑稳定性测量收紧：起音时刻改为在每块 64 毫秒缓冲内用峰值搜索定位真正的击弦点，抖动曲线放宽（噪声地板 0.006、系数减半），稳定跟节拍器练习能落到 70–90% 的合理区间，而不是约 50%
- 弹挑练习结算改为展示整场平均稳定性，而非停止瞬间的最后一次瞬时值
- 滚指均匀度评分改用中位数 + MAD 容差剔除离群间隔，使均匀度评分更稳定
- 三种界面语言与单元测试同步更新，匹配新增键（静音 / 范围 / 稳定性）

### v2.6 · 教练评分可靠性修复(2026-10-28)

- 指法教练生成的评价报告在正常练习下分数明显偏低。重新审视整条评分链路后，修复的是结构性缺陷，而不是调松阈值：
  - 节奏维度不再因起音少于 4 次就直接归零；短曲练习改为给一个保守保底分，不再吃光 25% 的权重
  - 演奏稳定性改为只平均真正有数据的子项，不再把五项硬平均、缺一项就记 0，因此漏采到音高或手型样本时，整维度不会被拖垮
  - 力度稳定性原本按逐帧 RMS 计算，而拨弦 RMS 天然是"尖峰—衰减"的锯齿，变异系数必然爆表恒为 0；现改为取每次起音的峰值包络再算离散度
  - 音色稳定性的过零率序列现在排除静音帧，消除有声段与静音段过零率差异巨大造成的爆表
  - 弹挑 / 轮指的节奏评分存在单位错配：指尖位移量被当成频率(Hz)区间去比对，恒判"太慢"；现改按位移量级映射运动强度
  - 新增真机日志，打印真实虎口角角度与手腕速度分布，待拿到一手数据后再标定剩余的手型阈值

### v2.7 · 扫弦方向修正、渐变花开与轮指实时指标(2026-10-29)

- 扫弦方向检测重写，改用自相关估起音基频，取代原先的 FFT 频谱质心走向。旧 FFT 路径算出的频谱其实是错的，方向判定基本等于随机；新判法读取最先拨动那根弦的基频(缠弦约 220 Hz 对子弦约 440 Hz)，无论顺序扫还是同品四音扫，都能干净区分下扫与上拂
- 扫弦方向平衡指标修正，既不会恒为 100%，也不会掉到接近零；现在如实反映整场练习的交替质量
- 轮指花开(轮指花开)由"达标转金色"改为"鲜艳度渐变"：练得越好花瓣越鲜艳，连续优秀的轮指仍会累积成重瓣
- 轮指均匀度改为练习中每 5 秒实时刷新，不再只在停下时才出，练习者能实时看到均匀度变化

### v2.8 · 历史排序与评价报告鼓励分(2026-10-29)

- 「我的成绩·历史」页把评价报告(评价报告)排到了游戏得分(游戏得分)前面，刚生成的报告会落在历史列表最上方，而不是压在练习记录底下
- 新增「游戏得分」分组标题的中英繁三语本地化键(游戏得分 / 遊戲得分 / Game Scores)，让两组历史排列一目了然
- 评价报告改为鼓励性重映射评分：报告只在端侧琵琶声判门确认正在弹琵琶之后才会生成，因此真实分低于 85 的维度会连续重映射到 87–95 区间（单调，越弱读数越低但始终高于 85，不会再每次都钉成 85），真实分 ≥85 的维度保持自然走向 100；各维度的详细子指标仍显示真实数值，反馈不失真

### v2.9 · 持续琵琶声门控与按时长分档评分(2026-10-29)

- 评价报告现在改为在检测到**持续**琵琶声之后才生成，而不再只看累计活跃帧数与起音数。连续性判定要求存在一段至少 0.75 秒的连续活跃发声、累计发声时长不低于 max(1.5 秒, 最长连续段×2)、起音次数 ≥3，并通过丰富度兜底（检出过清晰音高或有足够视频手型帧），从而堵住"敲两下桌子加环境噪声就能凑够帧数与起音、照样出高分报告"的误判漏洞
- 旧门控用"最长连续段 ÷ 录音总时长 ≥ 25%"作为发声判据，会被慢板乐曲里几秒的休止误杀——一首正常演奏的曲子反而被判成"没在弹"。新门控改用累计发声时长判定，休止本身不计入发声量，停顿再久也不会误杀
- 总体分改为按时长分档，不再是平铺重映射：0 秒从 85.1 起步，练满 1 分钟进入 90 分档，2 分钟 92，3 分钟 95，5 分钟进入 97+ 的"接近满分"档，10 分钟封顶 99.5；没到下一个里程碑前分数不会越过它，练得不够就拿不到高分
- 档内位置由真实表现叠加一份"每份报告共享、各维度再叠独立微扰"的随机基准决定，因此每次练习分数都不同，而综合分与四维度分始终自洽（不会综合 95、四个维度却全是 85）

### v3.0 · 以实测录音发声的虚拟琵琶(2026-11-19)

- 指法教练现在可以手上没有琴也练。屏幕上画出一台虚拟琵琶，靠摄像头演奏：左手定弦与品，右手弹或扫，声音在设备上实时渲染，不用音频文件，也不联网。目的是让指法练习不再受场地限制，也让演示只需要一部手机
- 发声用的不是物理模型，而是对着自己那把琵琶的录音拟合出来的模态模型。四根空弦各自带几十个分音，每个分音有自己的快衰减与慢衰减、成对分裂出的拍频，以及各自的立体声增益与相位；分音解释不掉的那部分能量单独成一层残余，跨弦耦合也从同一批录音里量出
- Karplus–Strong 波导仍留在 App 里，模型资源加载失败时自动回退，不会因为少一个文件就没声音
- 弹挑跑步的演示页也换成同一套声音，原来是三路正弦波手写叠加
- Debug 编译改为和 Release 一样开优化。未优化的合成循环在真机上会超过音频缓冲的截止时间，弹几下就整体静音；实测模型的分音数量比波导多，这条设置在这里不是可选项
- 指法教练多了两个完全不需要琵琶的入口。**指法演示**播一段内置的正确手型视频，并让同一套 Vision 管线逐帧分析它，于是 21 个关键点、虎口角度和教练反馈在没有摄像头、没有琴的情况下也能看完整；**演奏**直接进入虚拟琵琶。两者都完全离线，视频帧从本地解码，不出设备
- 弹挑跑步拆成两个模式，版式不变。**演示**循环播放一段脚本化的演奏，不用麦克风，用来讲清楚这个玩法；**弹挑**在屏幕下半给出一块四根弦的琴面，每拨一下小人前进一步。切换时只有下半区换内容，跑道和小人不会移位

### v3.1 · 按品读指尖，没按品发空弦(2026-11-19)

- 左手原来按手腕取位置，前提是手腕正对着所按的音。琴颈只有这么宽，手腕落在琴颈上时指尖已经越过去了，同一个姿势算出来的音低两三格，手腕一转标记就横向飘。现在改读食指指尖，指尖置信度不足时依次退到它后面的 DIP、PIP 关节，软边或自遮挡不会把音冻住
- 没按品时右手拨弦原来一声不出。现在由右手食指尖所在的弦发空弦；左手离开琴颈满 0.5 秒就把选择放开、回到空弦，而不是像原来那样碰过一次琴颈就把那个音一直粘到退出页面
- 手出画时 Vision 仍会给满 21 个点，并把腕点摆到手掌另一侧，五条掌骨于是从空处散开。与手掌形状矛盾的腕点——到四个掌指关节的距离比真手散得多的那种——从骨架里筛掉。这一条只管绘制，不进发声路径：在发声里误判一次，代价就是一次真的拨弦或扫弦没了
- 某根手指丢一帧时不再保留旧位置，原来那一跳回来会被当成一次拨弦，弹出一个并没有弹过的音

### v3.2 · 把拨弦和挥手区分开(2026-11-19)

- 手在琴颈上方挥动时会误响，原因是只要指尖在一帧里移动够远就算一次拨弦。现在加了两道区分：位移要横着穿弦而不是顺着弦走；手臂不能正在带手——手腕位移超过阈值的那一帧不再采信指尖的抖动，因为那是扫弦在发生。拨弦是手指的动作，扫弦是手臂的动作
- 力度改为跟着指尖一帧内的位移走：刚过拨弦阈值是 0.45，位移到屏宽 0.18 时是 1.0，中间线性。轻拨就轻，重弹就重。实测模型只在单一力度上量过，所以这只能改音量，不能让音色随力度变亮
- 比较之前先把两个轴都换算到屏宽这一把尺子上。Vision 把 x 除以宽、y 除以高，16:9 竖屏下同一个斜向动作会被读成两倍陡，方向判断会因此失真

### v3.3 · 拇指的挑，以及只认一个方向的笔画(2026-11-19)

- 拇指一直不出声。Vision 对看不见的关节不会丢弃，而是返回置信度 0 和一个猜出来的位置，那个点不跟着手指动。弹挑时拇指贴在食指侧面，指尖恰好是整只手上最看不见的点，于是这一次拨弦是从一个几乎不移动的假点上读的。现在每根手指都取关节链上第一个真正可信的点——拇指依次试指尖、指间关节、掌指关节，其余手指试指尖和远端指间关节——并且某一帧换了关节就作废这一帧，不把两点之间两厘米的距离算成一次拨弦
- 一根尺子量不了五根手指。食指从掌指关节摆，拇指从腕掌关节滚，同一个动作拇指尖端只走六成多的路，用食指的标准去量，挑每次都差一点。现在按指各给一个行程阈值，力度也从各自阈值起算，而不是共用一个
- 发声的弦改为「笔画穿过的那条线」，不再是「指尖最后落在哪条带里」。挑的终点刚好越过被挑的那根弦，旧算法把它四舍五入到隔壁带，于是跟左手按的弦对不上、静音丢掉；终点掉出琴颈更是直接拿不到弦。当笔画太短或正对镜头跨不过线时，改取离笔画中点最近的那根弦，并且只认完整、明确横向的一笔
- 笔画只认一个方向，跟琴一样：四指从屏幕右向左弹，拇指从左向右挑，反方向不发声。以前一笔会响两次——去程一次、回程一次——手往里扣也会弹出没碰过的音

### v3.4 · 空弦面板一笔只响一次(2026-11-23)

- 平板上弹挑跑步的 play 模式几乎每次过弦都响两下：落指在弦上一声，划过同一根弦隔零点几秒又一声。真弦上手指按在弦上不会响，划过去才响。现在落指只记起点、点亮弦做视觉反馈；发声只由「跨过弦」触发，整笔一根都没跨过才在抬手时补一声点按
- 跨线原来拿「终点纵坐标对应的弦横坐标」是否落在这一笔的横向区间里来判，两端还各留一点余量。弦是斜的，长一笔会差几个像素；余量又把慢划整笔吞掉（每帧位移不到一个余量），快划时还会漏掉中间几根。现在每帧直接解这一笔与每根斜弦的交点，取 t ∈ (0, 1]，不管手指多快多慢，一根弦只在真正穿过的那一帧响一次
- 「手指停着没动」的门槛从底图像素改成按屏幕点算。底图在面板上被放大，用底图像素设门槛会把慢划整笔吞掉（约 80 pt/s 就一声不出）；0.2 屏幕点只滤掉同一位置的重复上报

## 已知限制 / 待改进

- 分类器精度仍受训练数据分布限制。若真机 console 显示 `rms > 0.05` 但 `pipa < 0.3`,说明模型对当前麦克风音质判别力不足,需用 Create ML Sound Analysis 模板重训(每类 ≥ 30 条 16kHz 音频,通常 30 分钟内能出一个明显更好的模型)
- 免费 Apple ID 描述文件 7 天过期,需重连 Xcode 重签
- 摄像头 / 麦克风功能必须真机,模拟器无法演示
- 社交广场为离线演示版,排行榜 / 成就 / 好友 PK 数据存储本地 CoreData

## 许可证

个人项目源码,欢迎交流与学习。
