import SwiftUI
import WidgetKit

/// Widget Extension 入口（⚠️ 仅 Widget Extension target，主 App target 不要加入）。
/// 一个 extension 同时提供：
///   · SpeedWidget        → 小组件 1「速度主仪表」：大号 7 段码车速 +
///                          档位 / 电量 / AP / 限速 / 转向灯 / 双温度
///   · CarBodyWidget      → 小组件 2「车身状态地图」：俯视车身示意图，
///                          四轮胎压刹车温度 / 车门 / 前后备箱 / 盲区 /
///                          灯光位 / 电池加热（图标化，颜色即状态）
///   · PhoneGaugeWidget   → 小组件 3「TSL 手机仪表」：不连车辆，纯 iPhone
///                          GPS 速度 / 航向 / 海拔 / 坡度 / 纵向 G
///   · SpeedLiveActivity  → 车辆速度的实时载体（锁屏 / 灵动岛 / CarPlay）
///   · PhoneGaugeLiveActivity → 手机仪表的实时载体：后台也能秒级更新，
///                               解决桌面小组件切后台冻结的问题
@main
struct TSLWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SpeedWidget()
        CarBodyWidget()
        PhoneGaugeWidget()
        SpeedLiveActivity()
        PhoneGaugeLiveActivity()
    }
}
