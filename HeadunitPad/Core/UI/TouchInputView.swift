import UIKit

final class TouchInputView: UIView {
    var onTouch: (([(id: Int, point: CGPoint)], TouchAction, Int) -> Void)?
    private var touchIdMap: [ObjectIdentifier: Int] = [:]
    private var activePoints: [Int: CGPoint] = [:]
    private var nextTouchId: Int = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
    }

    private func sortedPointers() -> [(id: Int, point: CGPoint)] {
        return activePoints
            .map { (id: $0.key, point: $0.value) }
            .sorted { $0.id < $1.id }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let assignedId: Int
            if let existing = touchIdMap[key] {
                assignedId = existing
            } else {
                assignedId = nextTouchId
                nextTouchId += 1
                touchIdMap[key] = assignedId
            }

            activePoints[assignedId] = touch.location(in: self)
            let pointers = sortedPointers()
            let action: TouchAction = pointers.count == 1 ? .DOWN : .POINTER_DOWN
            let actionIndex = pointers.firstIndex(where: { $0.id == assignedId }) ?? 0
            onTouch?(pointers, action, actionIndex)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var changed = false
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let id = touchIdMap[key] else { continue }
            activePoints[id] = touch.location(in: self)
            changed = true
        }
        if changed {
            onTouch?(sortedPointers(), .MOVE, 0)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let id = touchIdMap[key] else { continue }
            activePoints[id] = touch.location(in: self)
            let pointers = sortedPointers()
            let action: TouchAction = pointers.count <= 1 ? .UP : .POINTER_UP
            let actionIndex = pointers.firstIndex(where: { $0.id == id }) ?? 0
            onTouch?(pointers, action, actionIndex)
            activePoints.removeValue(forKey: id)
            touchIdMap.removeValue(forKey: key)
        }

        if activePoints.isEmpty {
            nextTouchId = 0
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if let id = touchIdMap[key] {
                activePoints[id] = touch.location(in: self)
            }
        }
        let pointers = sortedPointers()
        if !pointers.isEmpty {
            onTouch?(pointers, .CANCEL, 0)
        }
        activePoints.removeAll()
        touchIdMap.removeAll()
        nextTouchId = 0
    }
}
