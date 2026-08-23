import Foundation

enum LocationService {
    static func distance(
        from latitude1: Double, longitude1: Double,
        to latitude2: Double, longitude2: Double
    ) -> Double {
        let earthRadius = 6371.0
        let dLat = (latitude2 - latitude1) * .pi / 180
        let dLon = (longitude2 - longitude1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude1 * .pi / 180) * cos(latitude2 * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadius * c
    }

    static func formatDistance(_ km: Double) -> String {
        if km < 1 {
            return "\(Int((km * 1000).rounded())) м"
        }
        return String(format: "%.1f км", km)
    }
}
