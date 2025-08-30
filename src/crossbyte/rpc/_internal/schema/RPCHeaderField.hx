package crossbyte.rpc._internal.schema;

using crossbyte.utils.EnumUtil;
/**
 * ...
 * @author Christopher Speciale
 */

/**
 * Represents a field in an RPC header.
 * Stores metadata about the field name, type, and size.
 */
@:forward abstract RPCHeaderField({field:RPCHeaderFieldType}) from {field:RPCHeaderFieldType}
	to {field:RPCHeaderFieldType} {
	/**
	 * Creates a new RPC header field.
	 * 
	 * @param field The field
     */
	public inline function new(field:RPCHeaderFieldType) {
		this = {field: field};
	}

	/**
	 * Returns a string representation of the field.
	 */
	public function toString():String {
        var f:String = EnumUtil.getValueName(this.field);
		return '[field="${f}"]';
	}  
}
