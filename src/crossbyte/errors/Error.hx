package crossbyte.errors;

import haxe.CallStack;

/**
	The base error type, carrying a message and a number, `errorId`.

	It extends `haxe.Exception`, so an Error can be thrown and caught like any
	other exception, and carries its own call stack: see `getCallStack`.
	Subclass it to name a kind of failure; the subclasses in this package
	(`ArgumentError`, `RangeError`, `IOError`, and the rest) are what CrossByte
	itself throws.
**/
#if !debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
class Error #if (haxe_ver >= "4.1.0") extends haxe.Exception #elseif (openfl_dynamic && haxe_ver < "4.0.0") implements Dynamic #end
{
	@:noCompletion private static inline var DEFAULT_TO_STRING:String = "Error";

	// @:noCompletion @:dox(hide) public static var length:Int;

	/**
		The number the failure's source gives it, where it has one: a MongoDB
		server's error code, a MySQL error number, or the `id` an application
		passed. 0 otherwise, which is every error CrossByte raises of its own.
	**/
	public var errorId(default, null):Int;

	/** What went wrong. **/
	#if (haxe_ver < "4.1.0")
	public var message:String;
	#end

	/** The error's kind: its class's name, `"Error"` for this one. **/
	public var name:String;

	/**
		@param message What went wrong.
		@param id The error's number, where it has one; see `errorId`.
	**/
	public function new(message:String = "", id:Int = 0) {
		#if (haxe_ver >= "4.1.0")
		super(message);
		#else
		this.message = message;
		#end

		this.errorId = id;
		name = "Error";
	}

	// @:noCompletion @:dox(hide) public static function getErrorMessage (index:Int):String;

	/**
		Returns this error's own call stack, captured where the error was
		constructed, as a string. Each frame is on its own line:

		```
		Called from OrderEntry.retrieveData (src/com/xyz/OrderEntry.hx line 995)
		Called from OrderEntry.init (src/com/xyz/OrderEntry.hx line 200)
		Called from OrderEntry.new (src/com/xyz/OrderEntry.hx line 148)
		```

		The stack belongs to this object, so it reads the same whether or not the
		error was ever thrown, and is unaffected by any other exception caught in
		between. It never returns `null`; an error constructed where no stack
		information is available returns an empty string.

		How much stack a build carries is a property of the build, not of this
		method. A release cpp build records none at all and returns an empty string:
		frames need `-D HXCPP_STACK_TRACE`, and file and line information needs
		`-D HXCPP_STACK_LINE` on top of it. On js, file and line information comes
		from source maps. Interp, jvm and node carry frames by default.

		It is the one way to read an error's stack, on every target.

		@returns	A string representation of the call stack.
	**/
	public function getCallStack():String {
		#if (haxe_ver >= "4.1.0")
		// This error's stack, not the interpreter's most recently caught one:
		// CallStack.exceptionStack() is global state, which answers "" for an
		// error never thrown, and another exception's stack once anything else
		// has been caught.
		return this.stack.toString();
		#else
		return CallStack.toString(CallStack.exceptionStack());
		#end
	}

	// @:noCompletion @:dox(hide) public static function throwError (type:Class<Dynamic>, index:UInt, ?p1:Dynamic, ?p2:Dynamic, ?p3:Dynamic, ?p4:Dynamic, ?p5:Dynamic):Dynamic;
	/**
		The message, or `name` when there is none.
		@returns	The error message.
	**/
	public #if (haxe_ver >= "4.1.0") override #end function toString():String {
		if (message != null && message != "") {
			return message;
		} else {
			return name != null ? name : DEFAULT_TO_STRING;
		}
	}
}
