import Foundation

// MARK: - JSON Schema

/// A lightweight JSON Schema representation for tool parameters
public final class JSONSchema: Codable, Sendable, Equatable {
    public var type: String
    public var schemaDescription: String?
    public var properties: [String: JSONSchemaProperty]?
    public var required: [String]?
    public var additionalProperties: Bool?
    public var items: JSONSchemaProperty?
    public var enumValues: [String]?

    public init(
        type: String = "object",
        description: String? = nil,
        properties: [String: JSONSchemaProperty]? = nil,
        required: [String]? = nil,
        additionalProperties: Bool? = nil,
        items: JSONSchemaProperty? = nil,
        enumValues: [String]? = nil
    ) {
        self.type = type
        self.schemaDescription = description
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
        self.items = items
        self.enumValues = enumValues
    }

    public static func == (lhs: JSONSchema, rhs: JSONSchema) -> Bool {
        lhs.type == rhs.type &&
        lhs.schemaDescription == rhs.schemaDescription &&
        lhs.required == rhs.required &&
        lhs.additionalProperties == rhs.additionalProperties &&
        lhs.enumValues == rhs.enumValues
    }

    private enum CodingKeys: String, CodingKey {
        case type, properties, required, additionalProperties, items
        case schemaDescription = "description"
        case enumValues = "enum"
    }
}

/// Property definition within a JSON Schema — class to allow recursive structure
public final class JSONSchemaProperty: Codable, Sendable, Equatable {
    public var type: String?
    public var propertyDescription: String?
    public var enumValues: [String]?
    public var defaultValue: AnyCodable?
    public var minimum: Double?
    public var maximum: Double?
    public var items: JSONSchemaProperty?
    public var properties: [String: JSONSchemaProperty]?
    public var required: [String]?
    public var additionalProperties: Bool?
    public var oneOf: [JSONSchemaProperty]?

    public init(
        type: String? = nil,
        description: String? = nil,
        enumValues: [String]? = nil,
        defaultValue: AnyCodable? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        items: JSONSchemaProperty? = nil,
        properties: [String: JSONSchemaProperty]? = nil,
        required: [String]? = nil,
        additionalProperties: Bool? = nil,
        oneOf: [JSONSchemaProperty]? = nil
    ) {
        self.type = type
        self.propertyDescription = description
        self.enumValues = enumValues
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.items = items
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
        self.oneOf = oneOf
    }

    public static func == (lhs: JSONSchemaProperty, rhs: JSONSchemaProperty) -> Bool {
        lhs.type == rhs.type && lhs.propertyDescription == rhs.propertyDescription
    }

    private enum CodingKeys: String, CodingKey {
        case type, minimum, maximum, items, properties, required, additionalProperties, oneOf
        case propertyDescription = "description"
        case enumValues = "enum"
        case defaultValue = "default"
    }
}

// MARK: - Tool Definition

/// Tool definition for LLM — name, description, and parameter schema
public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONSchema

    public init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Argument Validation

/// Validate tool call arguments against the schema
public func validateToolArguments(args: [String: AnyCodable], schema: JSONSchema) -> [String] {
    var errors: [String] = []

    // Check required properties
    if let required = schema.required {
        for key in required {
            if args[key] == nil {
                errors.append("Missing required parameter: \(key)")
            }
        }
    }

    // Check types for known properties
    if let properties = schema.properties {
        for (key, value) in args {
            guard let propSchema = properties[key] else {
                if schema.additionalProperties == false {
                    errors.append("Unknown parameter: \(key)")
                }
                continue
            }
            if let propType = propSchema.type {
                let isValid: Bool
                switch propType {
                case "string": isValid = value.stringValue != nil
                case "number", "integer": isValid = value.intValue != nil || value.doubleValue != nil
                case "boolean": isValid = value.boolValue != nil
                case "array": isValid = value.arrayValue != nil
                case "object": isValid = value.dictValue != nil
                default: isValid = true
                }
                if !isValid {
                    errors.append("Parameter '\(key)' should be \(propType)")
                }
            }
        }
    }

    return errors
}
