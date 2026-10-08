package crossbyte.utils;

class EnumUtil {
	/**
	 * Extracts only the name of the enum value, removing any parameters.
	 *
	 * @param e The enum value.
	 * @return The name of the enum without parameters.
	 */
	public static inline function getValueName(e:EnumValue):String {
		// The constructor's name as the enum knows it. This formatted the
		// whole value, parameters and all, with Std.string, and cut it at
		// the first "(".
		return e.getName();
	}

	/**
	 * Extracts only the parameters (values) of an enum instance.
	 *
	 * @param e The enum value.
	 * @return The parameters, in order: an empty array for a constructor
	 *         that has none.
	 */
	public static inline function getValue(e:EnumValue):Array<Dynamic> {
		return Type.enumParameters(e);
	}

	/**
	 * Returns a `{ name, value }` object containing the enum name and its parameters.
	 *
	 * @param e The enum value.
	 * @return The constructor's `name` and its parameters, as `value`.
	 */
	public static inline function getNameValuePair(e:EnumValue):EnumNameValue {
		return new EnumNameValue(getValueName(e), getValue(e));
	}
}

/**
	An enum value's constructor name and parameters, from
	`EnumUtil.getNameValuePair`. A class, built from a literal as the
	structure it replaces is, and fitting where `{name, value}` is asked for.
**/
@:structInit
final class EnumNameValue {
	public var name:String;
	public var value:Array<Dynamic>;

	public inline function new(name:String, value:Array<Dynamic>) {
		this.name = name;
		this.value = value;
	}
}
