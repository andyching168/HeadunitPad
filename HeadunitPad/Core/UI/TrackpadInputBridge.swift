import Foundation
import CoreGraphics

final class TrackpadInputBridge {
    typealias TouchSender = ([(id: Int, x: Int, y: Int)], TouchAction, Int) -> Void
    typealias CursorSink = (CGPoint) -> Void

    static let shared = TrackpadInputBridge()

    private let lock = NSLock()
    private var touchSender: TouchSender?
    private var cursorSinks: [UUID: CursorSink] = [:]
    private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
    private var pinchActive = false
    private var pinchRadiusNorm: CGFloat = 0.06
    private var dragActive = false
    private let speedKey = "trackpad-cursor-speed"
    private var cursorSpeed: CGFloat

    private init() {
        let stored = UserDefaults.standard.double(forKey: speedKey)
        if stored <= 0 {
            cursorSpeed = 1.0
        } else {
            cursorSpeed = CGFloat(stored)
        }
    }

    func setTouchSender(_ sender: @escaping TouchSender) {
        lock.lock()
        touchSender = sender
        lock.unlock()
    }

    @discardableResult
    func subscribeCursor(_ sink: @escaping CursorSink) -> UUID {
        lock.lock()
        let id = UUID()
        cursorSinks[id] = sink
        let cursor = cursorNorm
        lock.unlock()
        sink(cursor)
        return id
    }

    func unsubscribeCursor(_ id: UUID) {
        lock.lock()
        cursorSinks.removeValue(forKey: id)
        lock.unlock()
    }

    func moveCursor(delta: CGPoint, in areaSize: CGSize) {
        guard areaSize.width > 1, areaSize.height > 1 else { return }

        lock.lock()
        let speed = cursorSpeed
        lock.unlock()

        let dx = (delta.x / areaSize.width) * speed
        let dy = (delta.y / areaSize.height) * speed

        lock.lock()
        cursorNorm.x = min(max(cursorNorm.x + dx, 0), 1)
        cursorNorm.y = min(max(cursorNorm.y + dy, 0), 1)
        let cursor = cursorNorm
        let sinks = Array(cursorSinks.values)
        lock.unlock()

        for sink in sinks {
            sink(cursor)
        }

        let p = aaPoint(fromNormalized: cursor)
        send([(id: 0, x: p.x, y: p.y)], action: .MOVE, actionIndex: 0)
    }

    func setCursorSpeed(_ speed: CGFloat) {
        let clamped = min(max(speed, 0.2), 3.0)
        lock.lock()
        cursorSpeed = clamped
        lock.unlock()
        UserDefaults.standard.set(Double(clamped), forKey: speedKey)
    }

    func getCursorSpeed() -> CGFloat {
        lock.lock()
        let value = cursorSpeed
        lock.unlock()
        return value
    }

    func tap() {
        let p = aaPoint(fromNormalized: currentCursor())
        let pointers = [(id: 0, x: p.x, y: p.y)]
        send(pointers, action: .DOWN, actionIndex: 0)
        send(pointers, action: .UP, actionIndex: 0)
    }

    func beginDoubleTapDrag() {
        lock.lock()
        if dragActive {
            lock.unlock()
            return
        }
        dragActive = true
        lock.unlock()

        let p = aaPoint(fromNormalized: currentCursor())
        send([(id: 0, x: p.x, y: p.y)], action: .DOWN, actionIndex: 0)
    }

    func endDoubleTapDrag() {
        lock.lock()
        if !dragActive {
            lock.unlock()
            return
        }
        dragActive = false
        lock.unlock()

        let p = aaPoint(fromNormalized: currentCursor())
        send([(id: 0, x: p.x, y: p.y)], action: .UP, actionIndex: 0)
    }

    func isDoubleTapDragActive() -> Bool {
        lock.lock()
        let active = dragActive
        lock.unlock()
        return active
    }

    func beginPinch() {
        lock.lock()
        pinchActive = true
        pinchRadiusNorm = 0.06
        lock.unlock()

        let (a, b) = pinchPoints()
        send([(id: 0, x: a.x, y: a.y)], action: .DOWN, actionIndex: 0)
        send([(id: 0, x: a.x, y: a.y), (id: 1, x: b.x, y: b.y)], action: .POINTER_DOWN, actionIndex: 1)
    }

    func updatePinch(scale: CGFloat) {
        lock.lock()
        guard pinchActive else {
            lock.unlock()
            return
        }
        pinchRadiusNorm = min(max(0.02, 0.06 * scale), 0.25)
        lock.unlock()

        let (a, b) = pinchPoints()
        send([(id: 0, x: a.x, y: a.y), (id: 1, x: b.x, y: b.y)], action: .MOVE, actionIndex: 0)
    }

    func endPinch() {
        lock.lock()
        guard pinchActive else {
            lock.unlock()
            return
        }
        pinchActive = false
        lock.unlock()

        let (a, b) = pinchPoints()
        send([(id: 0, x: a.x, y: a.y), (id: 1, x: b.x, y: b.y)], action: .POINTER_UP, actionIndex: 1)
        send([(id: 0, x: a.x, y: a.y)], action: .UP, actionIndex: 0)
    }

    private func currentCursor() -> CGPoint {
        lock.lock()
        let cursor = cursorNorm
        lock.unlock()
        return cursor
    }

    private func pinchPoints() -> ((x: Int, y: Int), (x: Int, y: Int)) {
        let cursor = currentCursor()
        lock.lock()
        let radiusNorm = pinchRadiusNorm
        lock.unlock()

        let left = CGPoint(x: max(0, cursor.x - radiusNorm), y: cursor.y)
        let right = CGPoint(x: min(1, cursor.x + radiusNorm), y: cursor.y)
        return (aaPoint(fromNormalized: left), aaPoint(fromNormalized: right))
    }

    private func aaPoint(fromNormalized normalized: CGPoint) -> (x: Int, y: Int) {
        let dims = ProjectionSettings.effectiveVideoDimensions
        let x = Int(normalized.x * CGFloat(max(dims.width - 1, 1)))
        let y = Int(normalized.y * CGFloat(max(dims.height - 1, 1)))
        return (x, y)
    }

    private func send(_ pointers: [(id: Int, x: Int, y: Int)], action: TouchAction, actionIndex: Int) {
        lock.lock()
        let sender = touchSender
        lock.unlock()
        sender?(pointers, action, actionIndex)
    }
}
