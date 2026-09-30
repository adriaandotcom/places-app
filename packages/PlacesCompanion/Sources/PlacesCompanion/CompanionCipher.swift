import CryptoKit
import Foundation

public enum CompanionCipher {
    private static let context = Data("Places companion evidence v1".utf8)

    public static func newKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
    public static func seal<T: Encodable>(_ value: T, key: Data) throws -> Data {
        guard key.count == 32 else { throw CompanionError.missingKey }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 500_000 else { throw CompanionError.invalidPayload }
        return try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: context).combined!
    }
    public static func open<T: Decodable>(_ type: T.Type, data: Data, key: Data) throws -> T {
        guard key.count == 32 else { throw CompanionError.missingKey }
        guard data.count <= 500_028 else { throw CompanionError.invalidPayload }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data),
                                        using: SymmetricKey(data: key), authenticating: context)
        return try JSONDecoder().decode(type, from: plaintext)
    }
}
