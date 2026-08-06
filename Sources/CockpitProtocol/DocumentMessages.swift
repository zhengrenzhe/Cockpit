import Foundation
import CockpitTypes

public enum DocumentMessages {
    public static func encode(_ value: DocumentID) -> String {
        value.description
    }

    public static func decode(_ value: String) throws -> DocumentID {
        try decodeID(value, field: "document_id")
    }
}
