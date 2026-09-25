import Foundation

public enum DirectSignalingCodec {
    public static func encode(_ message: DirectSignalingMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(message)
    }
    
    public static func decode(_ data: Data) throws -> DirectSignalingMessage {
        let decoder = JSONDecoder()
        return try decoder.decode(DirectSignalingMessage.self, from: data)
    }
    
    public static func encodeJSON(_ message: DirectSignalingMessage) throws -> String {
        let data = try encode(message)
        return String(decoding: data, as: UTF8.self)
    }
    
    public static func decodeJSON(_ text: String) throws -> DirectSignalingMessage {
        let data = Data(text.utf8)
        return try decode(data)
    }
}
