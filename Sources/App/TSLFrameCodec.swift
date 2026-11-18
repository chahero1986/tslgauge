import Foundation

/// TSL 模块 BLE 帧编解码（从 wxapkg_app/app-service.js 的 BLE transport 模块逐位还原）
///
/// 线上帧结构（全部为无符号字节）：
///   [0x55, 0x7F, type, lenHi, lenLo, payload..., checksum]
///   checksum = (type + lenHi + lenLo + Σ payload[i]) & 0xFF
///   最大 payload 4096；默认 MTU 23 → 每片写入 20 字节（chunkSize = mtu - 3）
/// 接收侧按字节流状态机解析，粘包/拆包都要能处理（BLE notify 不保证帧对齐）。
enum TSLFrame {
    static let header1: UInt8 = 0x55   // JS 常量 h = 85
    static let header2: UInt8 = 0x7F  // JS 常量 p = 127
    static let maxPayloadLength = 4096
    static let defaultChunkSize = 20

    static func checksum(type: UInt8, length: Int, payload: [UInt8]) -> UInt8 {
        var sum = Int(type) + ((length >> 8) & 0xFF) + (length & 0xFF)
        for byte in payload { sum += Int(byte) }
        return UInt8(truncatingIfNeeded: sum)
    }

    static func encode(type: UInt8, payload: [UInt8] = []) -> Data {
        let length = payload.count
        var bytes: [UInt8] = [
            header1, header2, type,
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF)
        ]
        bytes.append(contentsOf: payload)
        bytes.append(checksum(type: type, length: length, payload: payload))
        return Data(bytes)
    }

    /// 按 MTU 切片写入（对应 JS 的 chunk + writeChain 串行写入）
    static func chunks(_ frame: Data, size: Int = defaultChunkSize) -> [Data] {
        let bytes = [UInt8](frame)
        var result: [Data] = []
        var index = 0
        while index < bytes.count {
            let end = min(index + size, bytes.count)
            result.append(Data(bytes[index..<end]))
            index = end
        }
        return result
    }
}

/// 字节流解码器：逐字节喂入 notify 数据，输出校验通过的完整帧
final class TSLFrameDecoder {
    private enum Stage { case h1, h2, type, lenHi, lenLo, payload, checksum }
    private var stage: Stage = .h1
    private var type: UInt8 = 0
    private var length = 0
    private var payload: [UInt8] = []

    struct Frame {
        let type: UInt8          // 帧号，例如 160 / 168 / 176 / 208
        let payload: [UInt8]
    }

    func feed(_ data: Data) -> [Frame] {
        var frames: [Frame] = []
        for byte in [UInt8](data) {
            switch stage {
            case .h1:
                if byte == TSLFrame.header1 { stage = .h2 }

            case .h2:
                stage = (byte == TSLFrame.header2) ? .type : .h1

            case .type:
                type = byte
                stage = .lenHi

            case .lenHi:
                length = Int(byte) << 8
                stage = .lenLo

            case .lenLo:
                length |= Int(byte)
                if length > TSLFrame.maxPayloadLength {
                    reset()
                    continue
                }
                payload = []
                payload.reserveCapacity(length)
                stage = (length == 0) ? .checksum : .payload

            case .payload:
                payload.append(byte)
                if payload.count >= length { stage = .checksum }

            case .checksum:
                let expected = TSLFrame.checksum(type: type, length: length, payload: payload)
                if byte == expected {
                    // JS 特例：type == 87 且长度为 0 时，payload 视为 [0]
                    let resolved = (type == 87 && length == 0) ? [UInt8(0)] : payload
                    frames.append(Frame(type: type, payload: resolved))
                }
                reset()
            }
        }
        return frames
    }

    func reset() {
        stage = .h1
        type = 0
        length = 0
        payload = []
    }
}
