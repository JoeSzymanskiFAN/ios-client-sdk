import Foundation

protocol DeprecatedCache {
    var cachedDataKey: String { get }
    var keyedValueCache: KeyedValueCaching { get }

    func retrieveFlags(for userKey: UserKey, and mobileKey: MobileKey) -> (featureFlags: [LDFlagKey: FeatureFlag]?, lastUpdated: Date?)
    func userKeys(from cachedUserData: [UserKey: [String: Any]], olderThan: Date) -> [UserKey]
    func removeData(olderThan expirationDate: Date)     // provided for testing, to allow the mock to override the protocol extension
}

extension DeprecatedCache {
    func removeData(olderThan expirationDate: Date) {
        guard let cachedUserData = keyedValueCache.dictionary(forKey: cachedDataKey) as? [UserKey: [String: Any]], !cachedUserData.isEmpty
        else { return } // no cached data
        let expiredUserKeys = userKeys(from: cachedUserData, olderThan: expirationDate)
        guard !expiredUserKeys.isEmpty
        else { return } // no expired user cached data, leave the cache alone
        guard expiredUserKeys.count != cachedUserData.count
        else {
            keyedValueCache.removeObject(forKey: cachedDataKey)        // all user cached data is expired, remove the cache key & values
            return
        }
        let unexpiredUserData: [UserKey: [String: Any]] = cachedUserData.filter { userKey, _ in
            !expiredUserKeys.contains(userKey)
        }
        keyedValueCache.set(unexpiredUserData, forKey: cachedDataKey)
    }
}

enum DeprecatedCacheModel: String, CaseIterable {
    case version5 // earlier versions are not supported
}

// updatedAt in cached data was used as the LDUser.lastUpdated, which is deprecated in the Swift SDK
private extension LDUser.CodingKeys {
    static let lastUpdated = "updatedAt"    // Can't use the CodingKey protocol here, this keeps the usage similar
}

extension Dictionary where Key == String, Value == Any {
    var lastUpdated: Date? {
        (self[LDUser.CodingKeys.lastUpdated] as? String)?.dateValue
    }
}
