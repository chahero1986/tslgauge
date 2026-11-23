import SwiftUI
import UIKit

/// 连接诊断页：明确回答「到底连上没有、卡在哪一步、接下来该做什么」。
///
/// 入口在主 App 全屏仪表右下角的小状态按钮（sheet 弹出），
/// 这样主界面和桌面 / CarPlay 小组件仍然保持「只有速度」的纯粹画面。
struct ConnectionDiagnosticsView: View {
    @ObservedObject var ble: TSLBLEManager
    @ObservedObject var log: BLELog
    @Environment(\.dismiss) private var dismiss

    @State private var passwordDraft = TSLConfig.defaultBLEPassword
    @State private var showCopied = false

    var body: some View {
        NavigationStack {
            List {
                statusSection
                actionSection
                dataSection
                linkDetailSection
                logSection
                noteSection
            }
            .navigationTitle("连接诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("日志已复制到剪贴板", isPresented: $showCopied) {
                Button("好", role: .cancel) { }
            } message: {
                Text("可直接粘贴发给别人排查；里面不含车辆位置等隐私数据。")
            }
        }
    }

    // MARK: - 状态卡

    private var statusSection: some View {
        Section("当前状态") {
            row("阶段", ble.stage.label, emphasized: true)
            row("状态", ble.connectionState)
            VStack(alignment: .leading, spacing: 6) {
                Text("下一步建议").font(.caption).foregroundStyle(.secondary)
                Text(ble.hint).font(.footnote)
            }
            .padding(.vertical, 4)
            row("已收到数据帧", "\(ble.frameCount)")
            row("距上次收帧", lastFrameText)
            row("密码 / 运行固件", ble.authenticated ? "已通过" : "未通过")
        }
    }

    private var actionSection: some View {
        Section("操作") {
            HStack(spacing: 10) {
                TextField("4 位密码", text: $passwordDraft)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Button("重新提交密码") { ble.submitPassword(passwordDraft) }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: 10) {
                Button("重新扫描") { ble.startScanning() }
                    .buttonStyle(.borderedProminent)
                Button("断开") { ble.disconnect() }
                    .buttonStyle(.bordered)
            }
            Button { copyLog() } label: {
                Label("复制全部连接日志", systemImage: "doc.on.doc")
            }
            Button(role: .destructive) { log.clear() } label: {
                Label("清空日志", systemImage: "trash")
            }
        }
    }

    private var dataSection: some View {
        Section("最近一帧字段预览（能看见数字就说明数据通了）") {
            if let lines = ble.extras?.previewLines {
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
            } else {
                Text("还没收到 176 仪表帧。若阶段停在「等待认证」，通常是密码或通知特征的问题。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var linkDetailSection: some View {
        Section("链路明细（排查 / 复制给他人）") {
            detail("设备", ble.deviceSummary)
            detail("实际服务 UUID", ble.serviceSummary)
            detail("FFF0 下全部特征", ble.characteristicSummary)
            detail("选定的写特征", ble.writeSummary)
            detail("选定的通知特征", ble.notifySummary)
            detail("已跳过的非 TSL 设备", ble.rejectedSummary)
        }
    }

    private var logSection: some View {
        Section("连接日志（\(log.entries.count) 条 · 最新在上）") {
            ForEach(Array(log.entries.reversed())) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.timeText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .leading)
                    Text(entry.level.marker)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(for: entry.level))
                    Text(entry.message)
                        .font(.caption)
                        .foregroundStyle(color(for: entry.level))
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var noteSection: some View {
        Section {
            Text("常见「连不上」原因：① 附近的蓝牙打印机 / 标签机同样广播 FFF0 服务，App 会逐台验证并自动跳过非 TSL 设备（见上方「已跳过」清单）；② 原「TSL模块管理」App 或另一台 iPhone 正占着同一个 BLE 连接（模块同时只允许一个 Central）；③ 模块未通电或不在广播；④ 模块处于 BOOT/DFU 固件升级模式；⑤ 4 位蓝牙密码不是 1234。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("数据仅供参考，以车辆自身仪表为准。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 小工具

    private func row(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(emphasized ? .body.bold() : .body)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var lastFrameText: String {
        guard let date = ble.lastFrameAt else { return "—" }
        return String(format: "%.1f 秒前", Date().timeIntervalSince(date))
    }

    private func color(for level: BLELogLevel) -> Color {
        switch level {
        case .info:  return .secondary
        case .ok:    return .green
        case .warn:  return .orange
        case .error: return .red
        case .data:  return .blue
        }
    }

    private func copyLog() {
        let header = [
            "TSLGauge 连接诊断",
            "导出时间: \(Date())",
            "阶段: \(ble.stage.label)",
            "状态: \(ble.connectionState)",
            "设备: \(ble.deviceSummary)",
            "实际服务: \(ble.serviceSummary)",
            "全部特征: \(ble.characteristicSummary)",
            "写特征: \(ble.writeSummary)",
            "通知特征: \(ble.notifySummary)",
            "已跳过的非 TSL 设备: \(ble.rejectedSummary)",
            "已收帧数: \(ble.frameCount)",
            "--- 日志 ---"
        ].joined(separator: "\n")
        UIPasteboard.general.string = header + "\n" + log.exportText()
        showCopied = true
    }
}
