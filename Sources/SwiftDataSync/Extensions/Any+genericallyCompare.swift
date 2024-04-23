import Foundation
import CloudKit
import CoreLocation

func genericallyCompare(_ l: Any, _ r: Any) -> Bool {
    switch (l, r) {
    case (let l as String, let r as String):
        return l == r
    case (let l as NSNumber, let r as NSNumber):
        return l.isEqual(to: r)
    case (let l as NSArray, let r as NSArray):
        return l == r
    case (let l as NSDate, let r as NSDate):
        return l == r
    case (let l as NSData, let r as NSData):
        return l == r
    case (let l as CKRecord.Reference, let r as CKRecord.Reference):
        return l == r
    case (let l as CKAsset, let r as CKAsset):
        return l == r
    case (let l as CLLocation, let r as CLLocation):
        return l == r
    case (let l as Optional<Any>, let r as Optional<Any>):
        return l == nil && r == nil
    default:
        return false
    }
}
