//
//  TcpConnection.swift
//  HeadunitPad
//
//  TCP Connection using Network.framework
//

import Foundation
import Network

enum TcpConnectionError: Error {
    case connectionFailed(String)
    case notConnected
    case timeout
    case writeFailed
    case readFailed
}

protocol TcpConnectionDelegate: AnyObject {
    func tcpConnectionDidConnect(_ connection: TcpConnection)
    func tcpConnectionDidDisconnect(_ connection: TcpConnection, error: Error?)
    func tcpConnection(_ connection: TcpConnection, didReceiveData data: Data)
}

class TcpConnection {
    weak var delegate: TcpConnectionDelegate?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.headunitpad.tcp", qos: .userInitiated)

    private(set) var isConnected = false
    private(set) var remoteEndpoint: String = ""

    init() {}

    func connect(host: String, port: UInt16, timeout: TimeInterval = 10) {
        disconnect()

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        connection = NWConnection(to: endpoint, using: parameters)

        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                self.isConnected = true
                self.remoteEndpoint = "\(host):\(port)"
                DispatchQueue.main.async {
                    self.delegate?.tcpConnectionDidConnect(self)
                }
                self.startReceiving()

            case .failed(let error):
                self.isConnected = false
                DispatchQueue.main.async {
                    self.delegate?.tcpConnectionDidDisconnect(self, error: error)
                }

            case .cancelled:
                self.isConnected = false
                DispatchQueue.main.async {
                    self.delegate?.tcpConnectionDidDisconnect(self, error: nil)
                }

            case .waiting(let error):
                print("TCP waiting: \(error)")

            default:
                break
            }
        }

        connection?.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    func send(data: Data, completion: ((Error?) -> Void)? = nil) {
        guard let connection = connection, isConnected else {
            completion?(TcpConnectionError.notConnected)
            return
        }

        connection.send(content: data, completion: .contentProcessed { error in
            completion?(error)
        })
    }

    func send(data: Data, timeout: TimeInterval, completion: ((Error?) -> Void)? = nil) {
        send(data: data, completion: completion)
    }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                DispatchQueue.main.async {
                    self.delegate?.tcpConnection(self, didReceiveData: data)
                }
            }

            if let error = error {
                print("TCP receive error: \(error)")
                self.disconnect()
                return
            }

            if isComplete {
                self.disconnect()
                return
            }

            self.startReceiving()
        }
    }
}
