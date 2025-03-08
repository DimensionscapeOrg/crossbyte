package crossbyte.rpc;
/**
 * ...
 * @author Christopher Speciale
 */

/**
 * Represents a field in an RPC header.
 * Stores metadata about the field name, type, and size.
 */
@:forward abstract RPCHeaderField({name:String, type:RPCValueType, size:Int, factory:RPCHeaderFieldType}) from {name:String, type:RPCValueType, size:Int}
	to {name:String, type:RPCValueType, size:Int} {
	/**
	 * Creates a new RPC header field.
	 * 
	 * @param name The field name.
	 * @param type The data type of the field.
	 * @param size The size of the field in bytes.
	 */
	public inline function new(name:String, type:RPCValueType, size:Int) {
		this = {name: name, type: type, size: size};
	}

	/**
	 * Returns a string representation of the field.
	 */
	public function toString():String {
		return '[name: "${this.name}", type: ${this.type}, size: ${this.size}]';
	}

	/**
	 * Checks if this field has a fixed size.
	 * 
	 * @return `true` if the field has a known fixed size, otherwise `false`.
	 */
	public function isFixedSize():Bool {
		return switch (this.type) {
			case VarString(_), VarArray(_, _), Blob(_): false;
			default: true;
		}
	}

	/**
	 * Gets the actual size of the field.
	 * 
	 * @return The field size in bytes (or -1 if variable-sized).
	 */
	public function getByteSize():Int {
		return switch (this.type) {
			case VarString(maxSize): maxSize != null ? maxSize : -1;
			case VarArray(_, maxSize): maxSize != null ? maxSize : -1;
			case Blob(maxSize): maxSize != null ? maxSize : -1;
			default: this.size;
		}
	}
}
