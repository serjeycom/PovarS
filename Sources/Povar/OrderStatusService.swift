import Fluent
import Vapor

func statusTitle(_ status: OrderStatus) -> String {
    switch status {
    case .new:
        return "Новый"
    case .accepted:
        return "Принят"
    case .cooking:
        return "Готовится"
    case .ready:
        return "Готов"
    case .onTheWay:
        return "В пути"
    case .delivered:
        return "Доставлен"
    case .cancelled:
        return "Отменен"
    }
}

func nextStatuses(for status: OrderStatus) -> [OrderStatus] {
    switch status {
    case .new:
        return [.accepted]
    case .accepted:
        return [.cooking]
    case .cooking:
        return [.ready]
    case .ready:
        return [.onTheWay, .delivered]
    case .onTheWay:
        return [.delivered]
    case .delivered, .cancelled:
        return []
    }
}

func isAllowedTransition(from current: OrderStatus, to next: OrderStatus) -> Bool {
    nextStatuses(for: current).contains(next)
}

func isClientCancelable(status: OrderStatus) -> Bool {
    switch status {
    case .new, .accepted, .onTheWay:
        return true
    case .cooking, .ready, .delivered, .cancelled:
        return false
    }
}

func isClientCancelable(order: Order) -> Bool {
    if order.typedStatus == .delivered || order.typedStatus == .cancelled {
        return false
    }
    if let scheduled = order.scheduledDate, !scheduled.isEmpty {
        return true
    }
    return isClientCancelable(status: order.typedStatus ?? .new)
}
