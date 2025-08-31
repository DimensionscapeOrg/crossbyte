package crossbyte.rpc._internal.schema;

import crossbyte.ds.OrderedMap;
import crossbyte.utils.EnumUtil;
import haxe.Json;

/**
 * ...
 * @author Christopher Speciale
 */
/**
 * Represents an RPC message header.
 * Defines the structure and rules for parsing and writing headers.
 */
class RPCHeader {
	/**
	 * The **alignment setting** for the header.
	 * 
	 * This determines how fields should be **aligned** in memory if alignment is required.
	 * 
	 * - **Default: `1` (no enforced alignment)**
	 * - If set to `4`, fields will align to the nearest **4-byte boundary**.
	 * - If set to `8`, fields will align to the nearest **8-byte boundary**.
	 * 
	 * @note Alignment is **not enforced here** but can be used in generated serialization code.
	 */
	public static inline final DEFAULT_MAX_MESSAGE_ID_SPACE = 65535;

	public static inline final DEFAULT_MAX_MESSAGE_SIZE = 65535;

	public var alignment:Int; // Optional alignment (default: 1, no alignment)

	private var __fields:OrderedMap<String, RPCHeaderField>;

	/**
	 * Creates a new immutable RPCHeader.
	 * 
	 * @param fields The ordered list of header fields.
	 * @param alignment Optional field alignment (default: 1).
	 */
	public function new(alignment:Int = 1) {
		this.__fields = new OrderedMap();
		this.alignment = alignment;

		__setup();
	}

	private inline function __setup():Void {
		this.__fields.set(EnumUtil.getValueName(RPCHeaderFieldType.MessageID(0)), new RPCHeaderField(MessageID(DEFAULT_MAX_MESSAGE_ID_SPACE)));
		this.__fields.set(EnumUtil.getValueName(RPCHeaderFieldType.MessageSize(0)), new RPCHeaderField(MessageSize(DEFAULT_MAX_MESSAGE_SIZE)));
	}

	/**
	 * Adds a field to the header in the specified position.
	 * Ensures that field names are unique.
	 * 
	 * @param field The field to add.
	 */
	public function addField(field:RPCHeaderField):Void {
		/* if(this.__fields.exists(field)){
				throw "The RPC Header can not accept duplicate fields.";
			}

			this.__fields.set(field); */
	}

	/**
	 * Removes a field by name.
	 * 
	 * @param name The name of the field to remove.
	 * @return The removed field, or throws an error if the field is not found.
	 */
	public function removeField(name:String):RPCHeaderField {
		/* var index = __fields.findIndex(f -> f.name == name);
			if (index == -1) throw 'Field not found: ${name}';
			return __fields.splice(index, 1)[0]; */
		return null;
	}

	/**
	 * Removes a field by index.
	 * 
	 * @param index The index of the field to remove.
	 * @return The removed field, or throws an error if the index is out of bounds.
	 */
	public function removeFieldAt(index:Int):RPCHeaderField {
		/* if (index < 0 || index >= __fields.length) throw 'Index out of bounds: ${index}';
			return __fields.splice(index, 1)[0]; */
		return null;
	}

	/**
	 * Checks if a field exists in the header.
	 * 
	 * @param name The name of the field.
	 * @return `true` if the field exists, `false` otherwise.
	 */
	public function hasField(name:String):Bool {
		/* return Lambda.exists(__fields, f -> f.name == name); */
		return null;
	}

	/**
	 * Exports the schema as a JSON string.
	 * This can be useful for debugging, documentation, or tooling.
	 * 
	 * The exported JSON includes:
	 * - `alignment`: The alignment setting of the header.
	 * - `fields`: An array of field definitions, each containing:
	 *   - `name`: The name of the field.
	 *   - `type`: The field type as a string.
	 *   - `size`: The size in bytes. If the field is **variable-sized**, this will be `-1`.
	 * 
	 * Example Output:
	 * ```json
	 * {
	 	*   "alignment": 1,
	 	*   "fields": [
	 	*     {
	 	*       "name": "messageId",
	 	*       "type": "UInt16",
	 	*       "size": 2
	 	*     },
	 	*     {
	 	*       "name": "username",
	 	*       "type": "VarString",
	 	*       "size": -1
	 	*     }
	 	*   ]
	 	* }
	 	* ```
	 	* 
	 	* @return A JSON string representation of the header schema.
	 */
	public function exportSchema():String {
		/* var schema = {
				alignment: alignment,
				fields: __fields.map(f -> {
					return {
						name: f.name,
						type: Std.string(f.type),
					};
				})
			};
			return Json.stringify(schema, null, "  "); */
		return null;
	}

	/**
	 * Serializes the header structure into a readable string.
	 */
	public function toString():String {
		/* return "[\n  " + __fields.map(f -> f.toString()).join(",\n  ") + "\n]"; */
		return null;
	}
}
