package crossbyte.rpc._internal.schema;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * Represents the various value types supported in the RPC system.
 * This enum defines data types that can be used for serialization, message structuring, 
 * and network communication in the RPC framework.
 */
enum RPCValueType {
	/**
	 * Unsigned 8-bit integer (0 to 255).
	 */
	UInt8;

	/**
	 * Unsigned 16-bit integer (0 to 65,535).
	 */
	UInt16;

	/**
	 * Unsigned 32-bit integer (0 to 4,294,967,295).
	 */
	UInt32;

	/**
	 * Signed 8-bit integer (-128 to 127).
	 */
	Int8;

	/**
	 * Signed 16-bit integer (-32,768 to 32,767).
	 */
	Int16;

	/**
	 * Signed 32-bit integer (-2,147,483,648 to 2,147,483,647).
	 */
	Int32;

	/**
	 * Signed 64-bit integer (-9,223,372,036,854,775,808 to 9,223,372,036,854,775,807).
	 */
	Int64;

	/**
	 * 32-bit floating-point number following the IEEE 754 standard.
	 */
	Float32;

	/**
	 * 64-bit floating-point number (double precision) following the IEEE 754 standard.
	 */
	Float64;

	/**
	 * Boolean value (true or false), typically stored as 1 byte (0 = false, 1 = true).
	 */
	Boolean;

	/**
	 * Timestamp value representing a point in time.
	 * Typically stored as an `Int64`, representing milliseconds since the Unix epoch (January 1, 1970).
	 */
	Timestamp;

	/**
	 * Represents an IPv6 address (128-bit).
	 * The storage format is expected to be a 16-byte array.
	 */
	IPv6;

	/**
	 * Represents an IPv4 address (32-bit).
	 * The storage format is expected to be a 4-byte array.
	 */
	IPv4;

	/**
	 * Represents a bit field for efficiently storing multiple boolean flags in a compact format.
	 * The field size determines how many bits are stored.
	 * 
	 * @param size The number of bits in the bit field.
	 */
	BitField(size:Int);

	/**
	 * Represents a Universally Unique Identifier (UUID).
	 * Typically stored as a 128-bit value (16 bytes).
	 */
	UUID(length:Int);

	/**
	 * Represents an enumerated value stored as a string.
	 * Enums are transmitted as human-readable names (e.g., `"WALK"`, `"JUMP"`).
	 * 
	 * @param name The string representation of the enumerated value.
	 */
	EnumValue(name:String);

	/**
	 * Represents a variable-length string with an optional maximum size.
	 * The storage format is typically a length-prefixed UTF-8 string.
	 * 
	 * @param maxSize The optional maximum size for the string (in bytes).
	 */
	VarString(?maxSize:Int);

	/**
	 * Represents a fixed-length string.
	 * The string is exactly `size` bytes long, including padding if necessary.
	 * 
	 * @param size The fixed size of the string in bytes.
	 */
	String(size:Int);

	/**
	 * Represents an array of a fixed length.
	 * The array consists of a predefined number of elements of a specified type.
	 * 
	 * @param type The type of the array elements.
	 * @param length The number of elements in the array.
	 */
	Array(type:RPCValueType, length:Int);

	/**
	 * Represents a variable-length array with an optional maximum size.
	 * The array contains a dynamic number of elements, prefixed by a length field.
	 * 
	 * @param type The type of the array elements.
	 * @param maxSize The optional maximum number of elements in the array.
	 */
	VarArray(type:RPCValueType, ?maxSize:Int);

	/**
	 * Represents a binary large object (BLOB) with an optional maximum size.
	 * Used for storing raw binary data.
	 * 
	 * @param maxSize The optional maximum size of the blob in bytes.
	 */
	Blob(?maxSize:Int);
}
