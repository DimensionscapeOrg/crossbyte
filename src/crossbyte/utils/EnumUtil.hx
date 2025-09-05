package crossbyte.utils;

class EnumUtil {
	/**
	 * Extracts only the name of the enum value, removing any parameters.
	 * 
	 * @param e The enum value.
	 * @return The name of the enum without parameters.
	 */
	public static inline function getValueName(e:EnumValue):String {
		var s = Std.string(e);
		var index = s.indexOf("(");
		return (index != -1) ? s.substr(0, index) : s;
	}

	/**
	 * Extracts only the parameters (values) of an enum instance.
	 * 
	 * @param e The enum value.
	 * @return An array of parameters or `null` if the enum has no parameters.
	 */
	public static inline function getValue(e:EnumValue):Dynamic {
		return Type.enumParameters(e);
	}

	/**
	 * Returns a `{ name, value }` object containing the enum name and its parameters.
	 * 
	 * @param e The enum value.
	 * @return An object with `name` (enum constructor) and `value` (parameters).
	 */
	public static inline function getNameValuePair(e:EnumValue):{name:String, value:Dynamic} {
		return {
			name: getValueName(e),
			value: getValue(e)
		};
	}
}
