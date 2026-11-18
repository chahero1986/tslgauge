import SwiftUI
import WidgetKit

/// Widget Extension 入口（⚠️ 仅 Widget Extension target，主 App target 不要加入）。
/// 一个 extension 同时提供：
///   · SpeedWidget        → iPhone 桌面 / 锁屏 / StandBy / iOS 26 CarPlay Dashboard
///   · SpeedLiveActivity  → 锁屏 / 灵动岛 / iOS 26 CarPlay Dashboard（秒级实时）
@main
struct TSLWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SpeedWidget()
        SpeedLiveActivity()
    }
}
