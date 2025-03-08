package crossbyte.rpc;

import haxe.ds.ReadOnlyArray;
import haxe.Json;
using Lambda;

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
     * A **read-only ordered list** of header fields.
     * 
     * This defines the structure of the header, including fixed-size and variable-size fields.
     * The order of fields **is important** and cannot be changed after initialization.
     */
	public var fields(get, null):ReadOnlyArray<RPCHeaderField>;

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
	public var alignment:Int; // Optional alignment (default: 1, no alignment)

	private var __fields:Array<RPCHeaderField>;

	private inline function get_fields():ReadOnlyArray<RPCHeaderField> {
		return __fields.copy();
	}

	/**
	 * Creates a new immutable RPCHeader.
	 * 
	 * @param fields The ordered list of header fields.
	 * @param alignment Optional field alignment (default: 1).
	 */
	public function new(?fields:Array<RPCHeaderField>, alignment:Int = 1) {
		this.__fields = [];

		if (fields != null) {
			var seen:Map<String, Bool> = [];
			for (field in fields) {
				if (seen.exists(field.name)) {
					throw 'Duplicate field name: ${field.name}';
				}
				seen.set(field.name, true);
				this.__fields.push(field);
			}
		}

		this.alignment = alignment;
	}

	/**
	 * Adds a field to the header in the specified position.
	 * Ensures that field names are unique.
	 * 
	 * @param field The field to add.
	 * @param index (Optional) The index to insert the field at. Defaults to the end of the array.
	 */
	public function addField(field:RPCHeaderField, ?index:Int):Void {
		if (__fields.exists(f -> f.name == field.name)) {
			throw 'Duplicate field name: ${field.name}';
		}

		if (index == null || index >= __fields.length) {
			__fields.push(field);
		} else {
			__fields.insert(index, field);
		}
	}

	/**
	 * Removes a field by name.
	 * 
	 * @param name The name of the field to remove.
	 * @return The removed field, or throws an error if the field is not found.
	 */
	public function removeField(name:String):RPCHeaderField {
		var index = __fields.findIndex(f -> f.name == name);
		if (index == -1) throw 'Field not found: ${name}';
		return __fields.splice(index, 1)[0];
	}

	/**
	 * Removes a field by index.
	 * 
	 * @param index The index of the field to remove.
	 * @return The removed field, or throws an error if the index is out of bounds.
	 */
	public function removeFieldAt(index:Int):RPCHeaderField {
		if (index < 0 || index >= __fields.length) throw 'Index out of bounds: ${index}';
		return __fields.splice(index, 1)[0];
	}

    /**
     * Checks if a field exists in the header.
     * 
     * @param name The name of the field.
     * @return `true` if the field exists, `false` otherwise.
     */
     public function hasField(name:String):Bool {
        return Lambda.exists(__fields, f -> f.name == name);
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
        var schema = {
            alignment: alignment,
            fields: __fields.map(f -> {
                return {
                    name: f.name,
                    type: Std.string(f.type),
                    size: f.isFixedSize() ? f.getByteSize() : -1
                };
            })
        };
        return Json.stringify(schema, null, "  ");
    }
    
	/**
	 * Gets all fixed-size fields in the header.
	 * 
	 * @return An array of fixed-size fields.
	 */
	public function getFixedFields():Array<RPCHeaderField> {
		return __fields.filter(f -> f.isFixedSize());
	}

	/**
	 * Gets all variable-size fields in the header.
	 * 
	 * @return An array of variable-size fields.
	 */
	public function getVariableFields():Array<RPCHeaderField> {
		return __fields.filter(f -> !f.isFixedSize());
	}

	/**
	 * Calculates the total size of the fixed portion of the header.
	 * This does not include variable-sized fields.
	 * 
	 * @return The total size in bytes.
	 */
	public function getFixedSize():Int {
		var size = 0;
		for (field in __fields) {
			if (field.isFixedSize()) {
				size += field.getByteSize();
			}
		}
		return size;
	}

	/**
	 * Serializes the header structure into a readable string.
	 */
	public function toString():String {
		return "[\n  " + __fields.map(f -> f.toString()).join(",\n  ") + "\n]";
	}
}

