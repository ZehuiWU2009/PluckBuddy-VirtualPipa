//
//  PipaOpenStringsPad.swift
//  PluckBuddy
//
//  Created by 吴泽荟（Zehui Wu） on 2026/11/17.
//
//  弹挑模式的空弦面板：真琴空弦特写 + 四根竖弦 + 指尖拖尾。
//
//  底图是一张 708 × 888 的真琴特写：四根弦占画面六成有余的宽度，复手和
//  穿弦孔压在底边，整个取景就是"弦 + 复手"两样东西。
//  底图上原来的弦已经抹掉，弦由代码来画——只有自己画的弦才能振动、
//  才能被指尖扫过时逐根判定。
//
//  手指划过去时画一条刀锋拖尾（头粗尾细、带光雾），扫到哪根弦就切哪根，
//  切中的位置迸出一小把火星——拨弦动作因此是"划"，不用去点。
//

import SwiftUI

// MARK: - 几何

/// 空弦区几何。所有数字都是底图上的像素坐标，
/// 照片、弦位、命中判定共用同一套，永远对得上。
enum PipaOpenStringsGeometry {

    /// 底图的像素尺寸。
    static let referenceSize = CGSize(width: 708, height: 888)

    static let stringCount = 4

    /// 整块面板相对底图的放大倍率。1.0 = 底图刚好铺满面板；
    /// 想再拉近只改这一个数，代价是左右各裁掉一点木纹。
    static let zoom: CGFloat = 1.0

    /// 四根弦在底图里的位置，各是一条直线 x = base + slope · y。
    ///
    /// 数字是把原照片逐行找暗列、再拟合出来的直线（已补上从暗边到弦心的 2px）。
    /// 弦序沿用合成器：0 是子弦（最细最右），3 是缠弦（最粗最左）。
    /// 四根并不完全平行——靠右的两根往下略微张、靠左的往回收，正是真琴的样子。
    private static let stringLines: [(base: CGFloat, slope: CGFloat)] = [
        (566.8, 0.0238),
        (426.1, 0.0063),
        (282.1, -0.0055),
        (140.8, -0.0222),
    ]

    /// 某根弦在底图坐标里的横坐标。
    static func stringX(_ index: Int, atY y: CGFloat) -> CGFloat {
        let line = stringLines[min(max(index, 0), stringCount - 1)]
        return line.base + line.slope * y
    }

    /// 面板尺寸 → 底图的缩放与原点。
    ///
    /// 横向铺满（cover）、水平居中、纵向钉住底边：弦、复手、穿弦孔全在画面下半，
    /// 面板窄一点时该裁掉的是上方的木纹，不是琴桥。
    static func layout(in size: CGSize) -> Layout {
        guard size.width > 0, size.height > 0 else {
            return Layout(scale: 0, size: .zero, origin: .zero)
        }

        let scale = max(size.width / referenceSize.width,
                        size.height / referenceSize.height) * zoom
        let width = referenceSize.width * scale
        let height = referenceSize.height * scale
        return Layout(scale: scale,
                      size: size,
                      origin: CGPoint(x: (size.width - width) / 2,
                                      y: min(size.height - height, 0)))
    }

    struct Layout {
        let scale: CGFloat
        let size: CGSize
        let origin: CGPoint

        /// 底图坐标 → 面板坐标。
        func point(x: CGFloat, y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }

        /// 面板纵坐标 → 底图纵坐标。
        func referenceY(_ screenY: CGFloat) -> CGFloat {
            guard scale > 0 else { return PipaOpenStringsGeometry.referenceSize.height }
            return (screenY - origin.y) / scale
        }

        /// 整张底图在面板里的位置。
        var imageRect: CGRect {
            CGRect(x: origin.x,
                   y: origin.y,
                   width: PipaOpenStringsGeometry.referenceSize.width * scale,
                   height: PipaOpenStringsGeometry.referenceSize.height * scale)
        }

        /// 面板上下边对应到的底图高度。弦就画在这个区间里，永远是满屏。
        var visibleReferenceRange: ClosedRange<CGFloat> {
            guard scale > 0 else { return 0...0 }
            let a = referenceY(0)
            let b = referenceY(size.height)
            return min(a, b)...max(a, b)
        }
    }

    /// 触摸点落在哪根弦上，返回合成器弦序（0 = 子弦）。
    ///
    /// 整个面板都响应：手指落在弦间的木纹上，按最近的那根算。
    /// 这一版刻意不留"死角"——上一版因为触摸区没覆盖全，出现过"点了没反应"的误判。
    static func string(at location: CGPoint, in size: CGSize) -> Int? {
        let layout = layout(in: size)
        guard layout.scale > 0 else { return nil }
        let y = clampedReferenceY(location.y, layout: layout)

        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0..<stringCount {
            let distance = abs(layout.point(x: stringX(index, atY: y), y: y).x - location.x)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// 一次手指移动（上一帧 → 这一帧）横跨了哪几根弦，按划过的先后返回。
    ///
    /// 快速扫弦时两帧之间可能已经跨过两三根，只看"当前点在哪根"会漏掉中间那些，
    /// 所以这里按线段求交：弦的横坐标落在这一段的横向区间里就算被划过。
    static func stringsCrossed(from start: CGPoint,
                               to end: CGPoint,
                               in size: CGSize) -> [Int] {
        let layout = layout(in: size)
        guard layout.scale > 0 else { return [] }
        let y = clampedReferenceY(end.y, layout: layout)

        let low = min(start.x, end.x)
        let high = max(start.x, end.x)
        // 位移太小不算划：手指贴着某根弦时会有 1pt 级的抖动，不能每次都触发。
        guard high - low > 1.5 else { return [] }

        var hits: [(index: Int, x: CGFloat)] = []
        for index in 0..<stringCount {
            let x = layout.point(x: stringX(index, atY: y), y: y).x
            // 两端各让出 1pt，避免"刚好停在弦上"被反复判成划过。
            if x > low + 1, x < high - 1 { hits.append((index, x)) }
        }
        hits.sort { start.x < end.x ? $0.x < $1.x : $0.x > $1.x }
        return hits.map(\.index)
    }

    /// 面板纵坐标 → 夹在底图上下边之间的底图纵坐标。
    private static func clampedReferenceY(_ screenY: CGFloat,
                                          layout: Layout) -> CGFloat {
        min(max(layout.referenceY(screenY), 0), referenceSize.height)
    }
}

// MARK: - 面板

/// 四根竖弦的空弦面板。手指划过即拨弦，扫过几根就响几根。
struct PipaOpenStringsPad: View {
    /// 拨弦回调：string 0..3（0 = 子弦，最高）、direction「弹」/「挑」。
    let onPluck: (Int, String) -> Void

    /// 手指当前压住的弦，用来做即时的按下反馈。
    @State private var pressedString: Int?
    /// 最近一次拨弦，驱动弦的余振与落点光晕。
    @State private var lastHit: Hit?
    /// 指尖轨迹，切水果式的拖尾就画在这上面。
    @State private var trail: [TrailSample] = []
    /// 切中弦时迸出的火星。
    @State private var sparks: [Spark] = []
    /// 切中瞬间的一圈冲击波。
    @State private var flashes: [Flash] = []
    /// 上一帧的落点，用来求这一段划过了哪几根弦。
    @State private var lastTouch: CGPoint?
    /// 这一划的方向：「挑」向右、「弹」向左。同一划里保持稳定。
    @State private var strokeDirection = "挑"
    /// 每根弦的上一次拨弦时间，防止手指抖动在弦边界上反复触发。
    @State private var lastPluckAt: [Int: Date] = [:]
    /// 手势结束后的收尾令牌，用来取消上一次排好的清理任务。
    @State private var decayToken = UUID()

    /// 余振时长与频率，取自 ElectricPipa 的弦振参数。
    private static let ringDuration: Double = 0.45
    private static let ringFrequency: Double = 9
    /// 拖尾寿命：手指停下后多久彻底消失。
    private static let trailLifetime: Double = 0.22
    /// 火星寿命上限。
    private static let sparkLifetime: Double = 0.46
    /// 拖尾刀锋的最大宽度（pt）。
    private static let maxBladeWidth: CGFloat = 21
    /// 手势结束后多久停掉逐帧重绘，别让 Canvas 空转。
    private static let settleDelay: Double = 0.55
    /// 同一根弦两次拨弦的最短间隔。
    private static let minPluckGap: Double = 0.07

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let layout = PipaOpenStringsGeometry.layout(in: size)
            ZStack(alignment: .topLeading) {
                instrument(layout: layout)
                overlay(layout: layout, size: size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size,
                                 layout: layout))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Open strings"))
            .accessibilityHint(Text("Sweep a finger across the four strings to pluck them."))
        }
    }

    // MARK: 画面

    /// 底图本身。只按 layout 摆放一次，不参与逐帧重绘。
    private func instrument(layout: PipaOpenStringsGeometry.Layout) -> some View {
        Image("PipaStringsBoard")
            .resizable()
            .interpolation(.high)
            .frame(width: layout.imageRect.width, height: layout.imageRect.height)
            .offset(x: layout.imageRect.minX, y: layout.imageRect.minY)
            .allowsHitTesting(false)
    }

    /// 弦、落点光晕、火星、拖尾，全部画在同一张 Canvas 上，层序就是数组的顺序。
    /// 用 TimelineView 读实时时钟：余振和拖尾都按绝对时间衰减，不依赖动画事务；
    /// 没有东西在动的时候把时钟停掉，不白跑每一帧。
    private func overlay(layout: PipaOpenStringsGeometry.Layout,
                         size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isAnimating)) { context in
            Canvas { canvas, _ in
                let now = context.date
                glow(in: canvas, layout: layout, now: now)
                for index in 0..<PipaOpenStringsGeometry.stringCount {
                    stroke(string: index, in: canvas, layout: layout, now: now)
                }
                sparkEffects(in: canvas, now: now)
                slashFlash(in: canvas, now: now)
                bladeTrail(in: canvas, now: now)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// 现在是否需要逐帧重绘：手指还按着，或者拖尾 / 余振 / 火星还没走完。
    private var isAnimating: Bool {
        if pressedString != nil { return true }
        if !trail.isEmpty || !sparks.isEmpty || !flashes.isEmpty { return true }
        if let hit = lastHit,
           Date().timeIntervalSince(hit.date) < Self.ringDuration { return true }
        return false
    }

    private func stroke(string index: Int,
                        in canvas: GraphicsContext,
                        layout: PipaOpenStringsGeometry.Layout,
                        now: Date) {
        let geometry = PipaOpenStringsGeometry.self
        let sway = swayAmount(for: index, now: now)
        let range = layout.visibleReferenceRange
        let topY = max(range.lowerBound, 0)
        let bottomY = min(range.upperBound, geometry.referenceSize.height)

        var path = Path()
        let steps = 40
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let y = topY + t * (bottomY - topY)
            // 余振的位移在两端收敛，弦不会从面板边缘"脱出去"。
            let x = geometry.stringX(index, atY: y) + sway * sin(t * .pi)
            let point = layout.point(x: x, y: y)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        // 真弦细得很：子弦不到一毫米，缠弦也不过两毫米。放大到特写尺度以后，
        // 线宽必须按点算、不跟着照片倍率涨，否则又变成"几根管子"。
        let width = 1.45 + CGFloat(index) * 0.32
        let lit = isLit(index) ? 1.0 : 0.0
        let tone = PipaOpenStringsPad.stringTone(index)

        // 极细的暗影把弦从木纹上"挑"出来，但不能画粗。
        canvas.stroke(path, with: .color(.black.opacity(0.16 + lit * 0.10)),
                      style: StrokeStyle(lineWidth: width + 0.35, lineCap: .round))
        canvas.stroke(path, with: .color(tone.opacity(0.92)),
                      style: StrokeStyle(lineWidth: width, lineCap: .round))
        // 顶光：偏左的一条窄高光，圆柱感就出来了。
        if width > 1.5 {
            var sheen = canvas
            sheen.translateBy(x: -width * 0.26, y: 0)
            sheen.stroke(path, with: .color(.white.opacity(0.22 + lit * 0.30)),
                         style: StrokeStyle(lineWidth: max(0.5, width * 0.28), lineCap: .round))
        }
    }

    /// 拨弦瞬间在落点打一圈暖光，指明是哪一根、哪一段响了。
    private func glow(in canvas: GraphicsContext,
                      layout: PipaOpenStringsGeometry.Layout,
                      now: Date) {
        guard let hit = lastHit else { return }
        let elapsed = now.timeIntervalSince(hit.date)
        guard elapsed >= 0, elapsed < Self.ringDuration else { return }
        let strength = 1 - elapsed / Self.ringDuration
        let center = layout.point(x: PipaOpenStringsGeometry.stringX(hit.string, atY: hit.y), y: hit.y)
        let radius = 22 * layout.scale
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        canvas.fill(Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.35).opacity(0.55 * strength),
                                          Color.clear]),
                        center: center,
                        startRadius: 1,
                        endRadius: radius))
    }

    /// 火星：一小把沿划线方向飞出去、受重力回落的光点。
    private func sparkEffects(in canvas: GraphicsContext, now: Date) {
        for spark in sparks {
            let elapsed = now.timeIntervalSince(spark.born)
            guard elapsed >= 0, elapsed < spark.life else { continue }
            let fade = 1 - elapsed / spark.life
            let t = CGFloat(elapsed)
            let x = spark.origin.x + spark.velocity.dx * t
            let y = spark.origin.y + spark.velocity.dy * t + 450 * t * t
            let vy = spark.velocity.dy + 900 * t
            let speed = max((spark.velocity.dx * spark.velocity.dx + vy * vy).squareRoot(), 0.001)
            // 沿速度方向拖一小段，看起来才是"飞出去的碎光"而不是静止的圆点。
            let length = min(speed * 0.018, 14)
            let dirX = spark.velocity.dx / speed
            let dirY = vy / speed
            var path = Path()
            path.move(to: CGPoint(x: x - dirX * length, y: y - dirY * length))
            path.addLine(to: CGPoint(x: x, y: y))
            let color = spark.warm
                ? Color(red: 1.0, green: 0.78, blue: 0.42)
                : Color(red: 1.0, green: 0.97, blue: 0.88)
            canvas.stroke(path,
                          with: .color(color.opacity(0.85 * fade * fade)),
                          style: StrokeStyle(lineWidth: max(spark.size * CGFloat(fade), 0.4),
                                             lineCap: .round))
        }
    }

    /// 切中瞬间的一道横向短闪：从 26pt 迅速收到 6pt 同时淡出。
    /// 不用圆环——圆环压在木纹上像水泡，横着的一道才读得出"切"。
    private func slashFlash(in canvas: GraphicsContext, now: Date) {
        for flash in flashes {
            let elapsed = now.timeIntervalSince(flash.born)
            guard elapsed >= 0, elapsed < flash.life else { continue }
            let fade = 1 - elapsed / flash.life
            let half = 6 + 20 * fade
            var path = Path()
            path.move(to: CGPoint(x: flash.center.x - half, y: flash.center.y))
            path.addLine(to: CGPoint(x: flash.center.x + half, y: flash.center.y))
            canvas.stroke(path,
                          with: .color(Color(red: 1.0, green: 0.86, blue: 0.60).opacity(0.85 * fade)),
                          style: StrokeStyle(lineWidth: 2.4 * fade + 0.6, lineCap: .round))
            canvas.stroke(path,
                          with: .color(.white.opacity(0.92 * fade)),
                          style: StrokeStyle(lineWidth: 1.1 * fade + 0.4, lineCap: .round))
        }
    }

    /// 刀锋拖尾：头粗尾细的一段光带。
    ///
    /// 面板是浅色木纹，纯白拖尾压不住，所以分三层叠：先一条压暗的"影"把光带
    /// 从木头上分离出来，再一层饱和的暖橙光雾，最后是接近全白的细芯。
    /// 每一小段的粗细按"离指尖多远"算，透明度按"采样点有多旧"算，
    /// 所以手指一停，尾巴自己就化掉了，不需要额外的动画状态机。
    private func bladeTrail(in canvas: GraphicsContext, now: Date) {
        var points: [CGPoint] = []
        var ages: [Double] = []
        for sample in trail {
            let age = now.timeIntervalSince(sample.time)
            guard age >= 0, age < Self.trailLifetime else { continue }
            if let last = points.last,
               hypot(sample.point.x - last.x, sample.point.y - last.y) < 0.6 { continue }
            points.append(sample.point)
            ages.append(age)
        }
        guard points.count >= 2 else { return }

        var lengths: [CGFloat] = [0]
        lengths.reserveCapacity(points.count)
        for index in 1..<points.count {
            let dx = points[index].x - points[index - 1].x
            let dy = points[index].y - points[index - 1].y
            lengths.append(lengths[index - 1] + (dx * dx + dy * dy).squareRoot())
        }
        let total = max(lengths[points.count - 1], 0.001)

        func fade(at index: Int) -> Double {
            Double(max(0, 1 - ages[index] / Self.trailLifetime))
        }
        func width(at index: Int) -> CGFloat {
            let t = CGFloat(lengths[index] / total)
            // 尾端强行收到一个尖：最后两成快速变细，看起来才像刀锋掠过，
            // 而不是一根被时间截断的带子。
            let tip = min(1, t * 5)
            return max(Self.maxBladeWidth * CGFloat(pow(Double(t), 0.62)) * tip, 0.5)
        }
        func segment(_ index: Int) -> Path {
            var path = Path()
            path.move(to: points[index - 1])
            path.addLine(to: points[index])
            return path
        }

        // 1) 压暗的影：模糊一层，只为了让亮光带在浅木纹上有边界。
        canvas.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            for index in 1..<points.count {
                layer.stroke(segment(index),
                             with: .color(.black.opacity(0.20 * fade(at: index))),
                             style: StrokeStyle(lineWidth: width(at: index) * 2.0,
                                                lineCap: .round))
            }
        }

        // 2) 暖橙光雾：整层模糊一次，饱和度高，和米色木头拉得开。
        canvas.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            for index in 1..<points.count {
                layer.stroke(segment(index),
                             with: .color(Color(red: 1.0, green: 0.52, blue: 0.12)
                                            .opacity(0.42 * fade(at: index))),
                             style: StrokeStyle(lineWidth: width(at: index) * 1.5,
                                                lineCap: .round))
            }
        }

        // 3) 刀身 + 白芯：越靠近指尖越亮、越粗，刀锋感来自这条细白线。
        for index in 1..<points.count {
            canvas.stroke(segment(index),
                          with: .color(Color(red: 1.0, green: 0.86, blue: 0.62)
                                        .opacity(0.38 * fade(at: index))),
                          style: StrokeStyle(lineWidth: width(at: index) * 0.92,
                                             lineCap: .round))
            canvas.stroke(segment(index),
                          with: .color(.white.opacity(0.92 * fade(at: index))),
                          style: StrokeStyle(lineWidth: max(width(at: index) * 0.38, 0.7),
                                             lineCap: .round))
        }

        // 4) 指尖：一点白热的光斑，手指在哪一眼就看得见。
        guard let head = points.last, let headAge = ages.last else { return }
        let headFade = max(0, 1 - headAge / Self.trailLifetime)
        let radius: CGFloat = 18
        canvas.drawLayer { layer in
            layer.addFilter(.blur(radius: 4))
            layer.fill(Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius,
                                              width: radius * 2, height: radius * 2)),
                       with: .radialGradient(
                           Gradient(colors: [Color(red: 1.0, green: 0.78, blue: 0.42)
                                                .opacity(0.85 * headFade), .clear]),
                           center: head, startRadius: 0, endRadius: radius))
        }
        canvas.fill(Path(ellipseIn: CGRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6)),
                    with: .color(.white.opacity(0.95 * headFade)))
    }

    // MARK: 交互

    private func dragGesture(size: CGSize,
                             layout: PipaOpenStringsGeometry.Layout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let isStart = lastTouch == nil
                let previous = lastTouch ?? value.location
                lastTouch = value.location
                appendTrail(value.location)

                // 方向只看这一帧的横向位移；还没动起来时沿用上一次。
                let dx = value.location.x - previous.x
                if abs(dx) > 0.8 {
                    strokeDirection = dx > 0 ? "挑" : "弹"
                }

                if isStart {
                    // 落指：按最近的那根算，点一下就响。
                    if let index = PipaOpenStringsGeometry.string(at: value.location, in: size) {
                        pressedString = index
                        pluck(index, at: value.location, layout: layout)
                    }
                } else {
                    let crossed = PipaOpenStringsGeometry.stringsCrossed(from: previous,
                                                                        to: value.location,
                                                                        in: size)
                    for index in crossed {
                        pressedString = index
                        pluck(index, at: value.location, layout: layout)
                    }
                    if crossed.isEmpty,
                       let index = PipaOpenStringsGeometry.string(at: value.location, in: size) {
                        pressedString = index
                    }
                }
                scheduleDecay()
            }
            .onEnded { _ in
                lastTouch = nil
                pressedString = nil
                scheduleDecay()
            }
    }

    /// 记一个轨迹采样点。手指没动就不记，免得数组被同一位置灌满。
    private func appendTrail(_ point: CGPoint) {
        let now = Date()
        if let last = trail.last,
           hypot(point.x - last.point.x, point.y - last.point.y) < 1.0 { return }
        trail.append(TrailSample(point: point, time: now))
        let cutoff = now.addingTimeInterval(-Self.trailLifetime)
        trail.removeAll { $0.time < cutoff }
    }

    private func pluck(_ string: Int, at location: CGPoint,
                       layout: PipaOpenStringsGeometry.Layout) {
        let now = Date()
        if let last = lastPluckAt[string], now.timeIntervalSince(last) < Self.minPluckGap {
            return
        }
        lastPluckAt[string] = now

        let geometry = PipaOpenStringsGeometry.self
        let y = min(max(layout.referenceY(location.y), 0), geometry.referenceSize.height)
        lastHit = Hit(string: string, date: now, y: y)
        let center = layout.point(x: geometry.stringX(string, atY: y), y: y)
        spawnSparks(at: center)
        flashes.append(Flash(center: center, born: now, life: 0.20))
        if flashes.count > 12 { flashes.removeFirst(flashes.count - 12) }
        onPluck(string, strokeDirection)
    }

    /// 切中弦的位置迸一把火星，方向跟着这一划走。
    private func spawnSparks(at point: CGPoint) {
        let now = Date()
        let base = strokeDirection == "挑" ? 0.0 : Double.pi
        for index in 0..<9 {
            let spread = (Double(index) / 8 - 0.5) * 2.4
            let angle = base + spread + Double.random(in: -0.14...0.14)
            let speed = Double.random(in: 110...260)
            sparks.append(Spark(origin: point,
                                velocity: CGVector(dx: cos(angle) * speed,
                                                   dy: sin(angle) * speed - 70),
                                born: now,
                                life: Double.random(in: 0.26...0.44),
                                size: CGFloat(Double.random(in: 2.0...4.0)),
                                warm: Bool.random()))
        }
        if sparks.count > 90 {
            sparks.removeFirst(sparks.count - 90)
        }
    }

    /// 手势停下后延迟清场：把拖尾和火星清掉，Canvas 才能把时钟停掉。
    /// 连续划动时每次都会重排，所以只在真正停手 0.55 秒后才生效。
    private func scheduleDecay() {
        let token = UUID()
        decayToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            guard decayToken == token else { return }
            trail.removeAll()
            sparks.removeAll()
            flashes.removeAll()
        }
    }

    /// 余振位移：指数式衰减的正弦，只作用在刚拨过的那根弦上。
    private func swayAmount(for index: Int, now: Date) -> CGFloat {
        guard let hit = lastHit, hit.string == index else { return 0 }
        let elapsed = now.timeIntervalSince(hit.date)
        guard elapsed >= 0, elapsed < Self.ringDuration else { return 0 }
        let strength = 1 - elapsed / Self.ringDuration
        // 位移按底图像素给：4.0 约等于一个弦径，缩到屏幕上差不多 2pt。
        return CGFloat(sin(elapsed * Self.ringFrequency * 2 * .pi) * strength * 4.0)
    }

    private func isLit(_ index: Int) -> Bool {
        pressedString == index
    }

    /// 弦色：0 是子弦（钢丝，偏冷灰亮），3 是缠弦（缠丝，偏暖褐暗）。
    /// 两端都压到比木纹深一档，细弦才不会在浅色面板上"消失"。
    private static func stringTone(_ index: Int) -> Color {
        let k = Double(3 - min(max(index, 0), 3)) / 3
        return Color(red: 0.42 + 0.24 * k,
                     green: 0.33 + 0.32 * k,
                     blue: 0.21 + 0.42 * k)
    }
}

// MARK: - 数据

/// 一次拨弦的落点。
private struct Hit {
    var string: Int
    var date: Date
    var y: CGFloat
}

/// 一个轨迹采样点。
private struct TrailSample {
    var point: CGPoint
    var time: Date
}

/// 一颗火星。位置和速度都在画的时候按时间解算，不需要逐帧累加。
private struct Spark {
    var origin: CGPoint
    var velocity: CGVector
    var born: Date
    var life: Double
    var size: CGFloat
    var warm: Bool
}

/// 一次切中的冲击波。
private struct Flash {
    var center: CGPoint
    var born: Date
    var life: Double
}

#Preview {
    PipaOpenStringsPad(onPluck: { _, _ in })
        .frame(width: 361, height: 426)
        .background(Color(red: 0.96, green: 0.94, blue: 0.88))
}
