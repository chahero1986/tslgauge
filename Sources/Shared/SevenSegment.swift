import SwiftUI

// MARK: - 速度分段配色
//
// 用户定义的规则（按数值，不区分 KM/H / MPH）：
//   0...60    绿色
//   61...100  黄色
//   >100      红色
//   无有效读数（档位无效 / 断连 / "--"）灰色
//
// 注：这是车速警示配色，与金融场景的「红涨绿跌」无关。
enum SpeedPalette {
    static let low = Color(red: 0.16, green: 0.88, blue: 0.36)
    static let mid = Color(red: 1.00, green: 0.78, blue: 0.10)
    static let high = Color(red: 1.00, green: 0.24, blue: 0.22)
    static let none = Color(red: 0.42, green: 0.45, blue: 0.48)

    static func color(for speed: Int?) -> Color {
        guard let speed = speed, speed >= 0 else { return none }
        if speed <= 60 { return low }
        if speed <= 100 { return mid }
        return high
    }

    /// 熄灭段：与点亮段同色、极低透明度，做出真实数码管的「暗段」质感
    static func inactive(for speed: Int?) -> Color {
        color(for: speed).opacity(0.13)
    }
}

// MARK: - 标准 7 段数码管（a~g 位掩码）
//
//      a
//   f     b
//      g
//   e     c
//      d
enum SevenSegment {
    static let a = 1, b = 2, c = 4, d = 8, e = 16, f = 32, g = 64
    static let allMask = a | b | c | d | e | f | g

    static func mask(for character: Character) -> Int {
        switch character {
        case "0": return a | b | c | d | e | f
        case "1": return b | c
        case "2": return a | b | d | e | g
        case "3": return a | b | c | d | g
        case "4": return b | c | f | g
        case "5": return a | c | d | f | g
        case "6": return a | c | d | e | f | g
        case "7": return a | b | c
        case "8": return a | b | c | d | e | f | g
        case "9": return a | b | c | d | f | g
        case "-": return g
        default:  return 0
        }
    }
}

/// 单个数字的 7 段图形。所有段都画成带斜切端点的六边形，
/// 归一化到 rect，任意尺寸自适应，不需要任何字体文件或 UIAppFonts 注册。
struct SevenSegmentShape: Shape {
    let mask: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        let t = min(rect.height * 0.145, rect.width * 0.24)
        let slant = t * 0.46
        let xL = rect.minX + t * 1.06
        let xR = rect.maxX - t * 1.06
        let xLeft = rect.minX + t * 0.5
        let xRight = rect.maxX - t * 0.5
        let yTop = rect.minY + t * 0.5
        let yMid = rect.midY
        let yBot = rect.maxY - t * 0.5
        let vTopStart = rect.minY + t * 1.06
        let vTopEnd = yMid - t * 0.60
        let vBotStart = yMid + t * 0.60
        let vBotEnd = rect.maxY - t * 1.06

        func hexagon(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        func horizontal(_ y: CGFloat) {
            hexagon([
                CGPoint(x: xL + slant, y: y - t / 2),
                CGPoint(x: xR - slant, y: y - t / 2),
                CGPoint(x: xR, y: y),
                CGPoint(x: xR - slant, y: y + t / 2),
                CGPoint(x: xL + slant, y: y + t / 2),
                CGPoint(x: xL, y: y)
            ])
        }
        func vertical(_ x: CGFloat, _ from: CGFloat, _ to: CGFloat) {
            hexagon([
                CGPoint(x: x, y: from),
                CGPoint(x: x + t / 2, y: from + slant),
                CGPoint(x: x + t / 2, y: to - slant),
                CGPoint(x: x, y: to),
                CGPoint(x: x - t / 2, y: to - slant),
                CGPoint(x: x - t / 2, y: from + slant)
            ])
        }

        if (mask & SevenSegment.a) != 0 { horizontal(yTop) }
        if (mask & SevenSegment.g) != 0 { horizontal(yMid) }
        if (mask & SevenSegment.d) != 0 { horizontal(yBot) }
        if (mask & SevenSegment.f) != 0 { vertical(xLeft, vTopStart, vTopEnd) }
        if (mask & SevenSegment.b) != 0 { vertical(xRight, vTopStart, vTopEnd) }
        if (mask & SevenSegment.e) != 0 { vertical(xLeft, vBotStart, vBotEnd) }
        if (mask & SevenSegment.c) != 0 { vertical(xRight, vBotStart, vBotEnd) }
        return path
    }
}

struct SevenSegmentDigit: View {
    let character: Character
    let color: Color
    let inactiveColor: Color

    var body: some View {
        ZStack {
            SevenSegmentShape(mask: SevenSegment.allMask).fill(inactiveColor)
            SevenSegmentShape(mask: SevenSegment.mask(for: character)).fill(color)
        }
    }
}

/// 多位数字：按可用空间自动把字号撑到最大（宽高同时约束），
/// 位数变化时（1 位 / 2 位 / 3 位）自动缩放，始终铺满。
struct SevenSegmentNumber: View {
    let text: String
    let color: Color
    let inactiveColor: Color

    private static let gapRatio: CGFloat = 0.13
    private static let aspectRatio: CGFloat = 1.85

    private var characters: [Character] {
        Array(text.isEmpty ? "--" : text)
    }

    private func digitWidth(for size: CGSize) -> CGFloat {
        let count = max(1, characters.count)
        let byWidth = size.width / (CGFloat(count) + CGFloat(count - 1) * Self.gapRatio)
        let byHeight = size.height / Self.aspectRatio
        return max(0, min(byWidth, byHeight))
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: digitWidth(for: geometry.size) * Self.gapRatio) {
                ForEach(0..<characters.count, id: \.self) { index in
                    SevenSegmentDigit(
                        character: characters[index],
                        color: color,
                        inactiveColor: inactiveColor
                    )
                    .frame(
                        width: digitWidth(for: geometry.size),
                        height: digitWidth(for: geometry.size) * Self.aspectRatio
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
        }
    }
}

/// 纯速度界面：整个画面只有数码管数字。
/// 默认完全无附加元素；把 showsStatusDot 设为 true 会在右上角多一个 5pt 状态点
/// （绿=实时、橙=快照/过期），用于不想放任何文字但仍需区分数据新鲜度的场景。
/// 快照 / 过期时整体降到 55% 不透明度，不会冒充实时。
struct SevenSegmentSpeedView: View {
    let text: String
    let speed: Int?
    let isLive: Bool
    var showsStatusDot: Bool = false

    private var color: Color { SpeedPalette.color(for: speed) }
    private var inactiveColor: Color { SpeedPalette.inactive(for: speed) }

    var body: some View {
        SevenSegmentNumber(text: text, color: color, inactiveColor: inactiveColor)
            .opacity(isLive ? 1.0 : 0.55)
            .overlay(alignment: .topTrailing) {
                if showsStatusDot {
                    Circle()
                        .fill(isLive ? color : Color.orange)
                        .frame(width: 5, height: 5)
                        .padding(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("车速 \(text)")
            .accessibilityValue(isLive ? "实时数据" : "数据已过期或为快照")
    }
}
