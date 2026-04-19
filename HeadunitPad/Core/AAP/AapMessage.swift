//
//  AapMessage.swift
//  HeadunitPad
//
//  Android Auto Protocol message framing
//

import Foundation

struct AapMessage {
    let channel: UInt8
    let flags: UInt8
    let type: UInt16
    let payload: Data

    static let FRAME_HEADER_SIZE = 6
    static let DEF_BUFFER_LENGTH = 131080

    init(channel: UInt8, flags: UInt8, type: UInt16, payload: Data) {
        self.channel = channel
        self.flags = flags
        self.type = type
        self.payload = payload
    }

    init?(data: Data) {
        guard data.count >= AapMessage.FRAME_HEADER_SIZE else {
            return nil
        }

        self.channel = data[0]
        self.flags = data[1]
        let length = UInt16(data[2]) << 8 | UInt16(data[3])
        self.type = UInt16(data[4]) << 8 | UInt16(data[5])

        let payloadStart = AapMessage.FRAME_HEADER_SIZE
        let payloadLength = Int(length) - 2

        guard data.count >= payloadStart + payloadLength else {
            return nil
        }

        self.payload = data.subdata(in: payloadStart..<(payloadStart + payloadLength))
    }

    func toData() -> Data {
        var buffer = Data()
        buffer.append(channel)
        buffer.append(flags)

        let length = UInt16(payload.count + 2)
        buffer.append(UInt8((length >> 8) & 0xFF))
        buffer.append(UInt8(length & 0xFF))

        buffer.append(UInt8((type >> 8) & 0xFF))
        buffer.append(UInt8(type & 0xFF))

        buffer.append(payload)

        return buffer
    }

    var totalSize: Int {
        return AapMessage.FRAME_HEADER_SIZE + payload.count
    }
}

enum AapMessageType: UInt16 {
    case VERSION_REQUEST = 1
    case VERSION_RESPONSE = 2
    case MESSAGE_ENCAPSULATED_SSL = 3
    case AUTH_COMPLETE = 4
    case SERVICE_DISCOVERY_REQUEST = 5
    case SERVICE_DISCOVERY_RESPONSE = 6
    case CHANNEL_OPEN_REQUEST = 7
    case CHANNEL_OPEN_RESPONSE = 8
    case CHANNEL_CLOSE_NOTIFICATION = 9
    case PING_REQUEST = 11
    case PING_RESPONSE = 12
    case NAV_FOCUS_REQUEST = 13
    case NAV_FOCUS_NOTIFICATION = 14
    case BYEBYE_REQUEST = 15
    case BYEBYE_RESPONSE = 16
    case AUDIO_FOCUS_RESPONSE = 17
    case AUDIO_FOCUS_REQUEST = 18
    case AUDIO_FOCUS_NOTIFICATION = 19
    case CAR_CONNECTED_DEVICES_REQUEST = 20
    case CAR_CONNECTED_DEVICES_RESPONSE = 21
    case USER_SWITCH_REQUEST = 22
    case USER_SWITCH_RESPONSE = 25
    case TOUCH_EVENT = 0x8001
    case KEY_CODE_EVENT = 101
    case VIDEO_FOCUS_REQUEST = 102
    case VIDEO_FOCUS_ACK = 103
    case SENSOR_EVENT = 200
    case VIDEO_CONFIG = 300
    case VIDEO_FRAME = 301
    case AUDIO_CONFIG = 400
    case AUDIO_FOCUS = 401
    case AUDIO_FRAME = 402
}

enum AapFlags {
    static let CONTROL_MESSAGE: UInt8 = 3
    static let CONTROL_RESPONSE: UInt8 = 2
    static let NORMAL_MESSAGE: UInt8 = 0
}
