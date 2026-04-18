//
//  AccessoryConnection.swift
//  HeadunitPad
//
//  Protocol for connection access - mirrors Android's AccessoryConnection interface
//

import Foundation

protocol AccessoryConnection {
    var isConnected: Bool { get }
    var isSingleMessage: Bool { get }

    func sendBlocking(_ data: Data, timeout: TimeInterval) -> Int
    func recvBlocking(size: Int, timeout: TimeInterval) -> Data
}