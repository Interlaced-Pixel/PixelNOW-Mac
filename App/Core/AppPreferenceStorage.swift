import Foundation

public struct AppPreferenceStorage: @unchecked Sendable {
    public static let standard = AppPreferenceStorage(defaults: .standard, defaultsDomain: "com.interlacedpixel.pixelnow")

    private let defaults: UserDefaults
    private let defaultsDomain: String
    public init(defaults: UserDefaults, defaultsDomain: String) {
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
    }

    public func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    public func array(forKey key: String) -> [Any]? {
        object(forKey: key) as? [Any]
    }

    public func dictionary(forKey key: String) -> [String: Any]? {
        object(forKey: key) as? [String: Any]
    }

    public func object(forKey key: String) -> Any? {
        if let canonical = defaults.persistentDomain(forName: defaultsDomain)?[key] {
            return canonical
        }
        if let value = defaults.object(forKey: key) {
            return value
        }
        return nil
    }

    public func double(forKey key: String) -> Double {
        if let number = object(forKey: key) as? NSNumber {
            return number.doubleValue
        }
        if let string = object(forKey: key) as? String {
            return Double(string) ?? 0
        }
        return 0
    }

    public func set(_ value: Any, forKey key: String) {
        setCanonicalValue(value, forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
        var domain = defaults.persistentDomain(forName: defaultsDomain) ?? [:]
        domain.removeValue(forKey: key)
        defaults.setPersistentDomain(domain, forName: defaultsDomain)
    }

    public func synchronize() {
        defaults.synchronize()
    }

    public func storedValue(forKey key: String, preferCanonicalDomain: Bool) -> Any? {
        if preferCanonicalDomain {
            return defaults.persistentDomain(forName: defaultsDomain)?[key] ?? object(forKey: key)
        }
        return object(forKey: key) ?? defaults.persistentDomain(forName: UserDefaults.globalDomain)?[key]
    }

    public func setCanonicalInt(_ value: Int, forKey key: String) {
        setCanonicalValue(value, forKey: key)
    }

    private func setCanonicalValue(_ value: Any, forKey key: String) {
        var domain = defaults.persistentDomain(forName: defaultsDomain) ?? [:]
        domain[key] = value
        defaults.setPersistentDomain(domain, forName: defaultsDomain)
    }

}
