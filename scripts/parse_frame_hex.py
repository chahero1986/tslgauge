"""TSL 模块 BLE 抓包解析工具（与线上小程序 JS 逻辑逐位一致）

用法:
  python parse_frame_hex.py --selftest
  python parse_frame_hex.py "55 7f b0 00 21 58 18 ..."
  python parse_frame_hex.py --file dump.txt       # 文件里可含多行 hex/空格分隔

帧格式: 55 7F type lenHi lenLo payload... checksum
  checksum = (type + lenHi + lenLo + sum(payload)) & 0xFF
  176 帧 payload >= 33 字节时为完整仪表帧，speedRaw = LE32(payload[0:4]) & 0x1FF
"""
import sys
import re
import struct

HEADER1, HEADER2 = 0x55, 0x7F
MAX_PAYLOAD = 4096
GEAR_LABELS = ["0", "P", "R", "N", "D"]
TURN_LABELS = ["关闭", "左转", "右转", "双闪"]
HEAT_LABELS = ["关闭", "加热", "预热", "保温"]


def checksum(frame_type, payload):
    length = len(payload)
    total = (frame_type & 0xFF) + ((length >> 8) & 0xFF) + (length & 0xFF)
    total += sum(payload)
    return total & 0xFF


def build_frame(frame_type, payload=()):
    payload = list(payload)
    length = len(payload)
    body = [HEADER1, HEADER2, frame_type & 0xFF,
            (length >> 8) & 0xFF, length & 0xFF] + payload
    body.append(checksum(frame_type, payload))
    return bytes(body)


def decode_stream(data):
    """逐字节状态机，返回 [(type, payload)]；自动处理粘包/拆包"""
    stage, frame_type, length, payload, out = 0, 0, 0, [], []
    for byte in data:
        if stage == 0:
            if byte == HEADER1:
                stage = 1
        elif stage == 1:
            stage = 2 if byte == HEADER2 else 0
        elif stage == 2:
            frame_type, stage = byte, 3
        elif stage == 3:
            length, stage = byte << 8, 4
        elif stage == 4:
            length |= byte
            if length > MAX_PAYLOAD:
                stage, frame_type, length, payload = 0, 0, 0, []
                continue
            payload = []
            stage = 6 if length == 0 else 5
        elif stage == 5:
            payload.append(byte)
            if len(payload) >= length:
                stage = 6
        elif stage == 6:
            if byte == checksum(frame_type, payload):
                out.append((frame_type, [0] if frame_type == 87 and length == 0 else payload))
            stage, frame_type, length, payload = 0, 0, 0, []
    return out


def parse_gauge(payload):
    if len(payload) < 4:
        return None
    head = struct.unpack_from("<I", bytes(payload), 0)[0]
    speed_raw = head & 0x1FF
    gear = (head >> 9) & 0x7
    valid = 1 <= gear <= 4
    full = len(payload) >= 33
    b17 = payload[17] if full else 0
    result = {
        "speedRaw": speed_raw,
        "speedText": (str(speed_raw) if valid else "--"),
        "gear": gear,
        "gearLabel": GEAR_LABELS[gear] if gear < len(GEAR_LABELS) else str(gear),
        "turn": (head >> 12) & 0x3,
        "turnLabel": TURN_LABELS[(head >> 12) & 0x3],
        "autoPilot": (head >> 14) & 0x3,
        "door": (head >> 16) & 0xF,
        "unit": "KM/H" if (b17 >> 6) & 1 else "MPH",
        "batteryHeat": HEAT_LABELS[(b17 >> 4) & 3] if full else "-",
        "handsOn": bool((b17 >> 7) & 1) if full else False,
        "hasFullFrame": full,
        "speedRingPercent": min(100, round(speed_raw / 120 * 100)),
        "length": len(payload),
    }
    if len(payload) >= 12:
        result["tirePressureBar"] = [
            0 if payload[i] in (0, 255) else round(0.025 * payload[i], 3)
            for i in range(8, 12)
        ]
    return result


def hex_to_bytes(text):
    cleaned = re.sub(r"[^0-9a-fA-F]", "", text)
    if len(cleaned) % 2:
        raise ValueError("hex 字符数为奇数")
    return bytes.fromhex(cleaned)


def selftest():
    payload = bytearray(33)
    head = (88 & 0x1FF) | (4 << 9) | (1 << 12)
    payload[0:4] = struct.pack("<I", head)
    payload[17] = 1 << 6
    frame = build_frame(176, payload)
    decoded = decode_stream(frame)
    assert len(decoded) == 1 and decoded[0][0] == 176
    state = parse_gauge(decoded[0][1])
    assert state["speedRaw"] == 88 and state["gearLabel"] == "D"
    assert state["unit"] == "KM/H" and state["speedText"] == "88"
    assert state["hasFullFrame"] and state["speedRingPercent"] == 73
    # 粘包 + 拆包
    assert len(decode_stream(frame + frame)) == 2
    assert len(decode_stream(frame[:10] + frame[10:])) == 1
    print("frame:", frame.hex(" "))
    print("decoded:", state)
    print("PASS: 帧头/校验/粘包/速度位域全部与线上 JS 逻辑一致")


def main():
    if "--selftest" in sys.argv or len(sys.argv) == 1:
        selftest()
        return
    if "--file" in sys.argv:
        text = open(sys.argv[sys.argv.index("--file") + 1], encoding="utf-8").read()
    else:
        text = " ".join(a for a in sys.argv[1:])
    frames = decode_stream(hex_to_bytes(text))
    print(f"解析到 {len(frames)} 个有效帧")
    for frame_type, payload in frames:
        if frame_type == 176:
            print(f"  [176 仪表] {parse_gauge(payload)}")
        else:
            print(f"  [{frame_type}] len={len(payload)} head={payload[:8].hex(' ')}")


if __name__ == "__main__":
    main()
