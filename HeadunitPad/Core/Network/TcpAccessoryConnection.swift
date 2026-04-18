//
//  TcpAccessoryConnection.swift
//  HeadunitPad
//
//  Adapter that wraps TcpHandler to conform to AccessoryConnection protocol
//  Mirrors Android's AccessoryConnection interface
//

import Foundation
import Network

class TcpAccessoryConnection: AccessoryConnection {
    private let tcpHandler: TcpHandler
    private let queue = DispatchQueue(label: "com.headunitpad.accessory.connection", qos: .userInitiated)
    private let receiveBuffer = DispatchQueue(label: "com.headunitpad.accessory.receiveBuffer", qos: .userInitiated)

    private var dataBuffer = Data()
    private let bufferLock = NSLock()
    private let dataAvailable = DispatchSemaphore(value: 0)

    var isConnected: Bool {
        return tcpHandler.isConnected
    }

    var isSingleMessage: Bool {
        return false
    }

    init(tcpHandler: TcpHandler) {
        self.tcpHandler = tcpHandler
        tcpHandler.delegate = self
    }

    func sendBlocking(_ data: Data, timeout: TimeInterval) -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Int = -1

        tcpHandler.send(data) { error in
            if error == nil {
                result = data.count
            } else {
                result = -1
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            return -1
        }

        return result
    }

    func recvBlocking(size: Int, timeout: TimeInterval) -> Data {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            bufferLock.lock()
            if dataBuffer.count >= size {
                let result = dataBuffer.prefix(size)
                dataBuffer.removeFirst(min(size, dataBuffer.count))
                bufferLock.unlock()
                return Data(result)
            }
            bufferLock.unlock()

            let remainingTime = deadline.timeIntervalSinceNow
            if remainingTime <= 0 {
                bufferLock.lock()
                let partial = dataBuffer.count > 0 ? dataBuffer : Data()
                dataBuffer.removeAll()
                bufferLock.unlock()
                return partial
            }

            let waitResult = dataAvailable.wait(timeout: .now() + min(remainingTime, 0.1))
            if waitResult == .timedOut {
                bufferLock.lock()
                if dataBuffer.count > 0 {
                    let partial = dataBuffer
                    dataBuffer.removeAll()
                    bufferLock.unlock()
                    return partial
                }
                bufferLock.unlock()

                if Date() >= deadline {
                    return Data()
                }
            }
        }
    }

    private func appendToBuffer(_ data: Data) {
        bufferLock.lock()
        dataBuffer.append(data)
        bufferLock.unlock()
        dataAvailable.signal()
    }
}

extension TcpAccessoryConnection: TcpHandlerDelegate {
    func tcpHandlerDidConnect(_ handler: TcpHandler) {
    }

    func tcpHandler(_ handler: TcpHandler, didFailWithError error: Error) {
        dataAvailable.signal()
    }

    func tcpHandler(_ handler: TcpHandler, didReceiveData data: Data) {
        appendToBuffer(data)
    }

    func tcpHandlerDidDisconnect(_ handler: TcpHandler) {
        dataAvailable.signal()
    }
}