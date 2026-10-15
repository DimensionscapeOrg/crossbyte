package crossbyte._internal;

/**
	A caught error as the text of a message of CrossByte's.
**/
class ErrorText {
	/**
		What `e` says: on PHP an exception's message alone, where its text
		would carry its stack trace as well; elsewhere `e` as `Std.string`
		writes it.
	**/
	public static function of(e:Dynamic):String {
		#if php
		if (Std.isOfType(e, php.Throwable)) {
			return (cast e : php.Throwable).getMessage();
		}
		#end
		return Std.string(e);
	}
}
