package crossbyte.errors;

import haxe.CallStack;

/**
	The Error class contains information about an error that occurred in a script. In
	developing ActionScript 3.0 applications, when you run your compiled code in the
	debugger version of a Flash runtime, a dialog box displays exceptions of type Error,
	or of a subclass, to help you troubleshoot the code. You create an Error object by
	using the Error constructor function. Typically, you throw a new Error object from
	within a `try` code block that is caught by a `catch` code block.
	You can also create a subclass of the Error class and throw instances of that subclass.
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
		Contains the reference number associated with the specific error message. For a
		custom Error object, this number is the value from the id parameter supplied in the
		constructor.
	**/
	public var errorID(default, null):Int;

	/**
		Contains the message associated with the Error object. By default, the value of
		this property is "Error". You can specify a message property when you create an
		Error object by passing the error string to the Error constructor function.
	**/
	#if (haxe_ver < "4.1.0")
	public var message:String;
	#end

	/**
		Contains the name of the Error object. By default, the value of this property is
		"Error".
	**/
	public var name:String;

	/**
		Creates a new Error object. If message is specified, its value is assigned to the
		object's Error.message property.
		@param	message	A string associated with the Error object; this parameter is optional.
		@param	id	A reference number to associate with the specific error message.
	**/
	public function new(message:String = "", id:Int = 0) {
		#if (haxe_ver >= "4.1.0")
		super(message);
		#else
		this.message = message;
		#end

		this.errorID = id;
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

		@returns	A string representation of the call stack.
	**/
	public function getCallStack():String {
		#if (haxe_ver >= "4.1.0")
		// This error's stack, not the interpreter's most recently caught one.
		// CallStack.exceptionStack() is global state: it answered "" for an error
		// that was never thrown, and answered with an unrelated exception's stack
		// once anything else had been caught, on whichever Error you asked.
		return this.stack.toString();
		#else
		return CallStack.toString(CallStack.exceptionStack());
		#end
	}

	#if !(java || jvm)
	// AS3-compatible alias. Unavailable on java/jvm, where the name is taken by
	// haxe.Exception/Throwable.getStackTrace() with an incompatible (native
	// array) signature that Java cannot return-type-overload. Use getCallStack().
	public inline function getStackTrace():String {
		return getCallStack();
	}
	#end

	// @:noCompletion @:dox(hide) public static function throwError (type:Class<Dynamic>, index:UInt, ?p1:Dynamic, ?p2:Dynamic, ?p3:Dynamic, ?p4:Dynamic, ?p5:Dynamic):Dynamic;
	/**
		Returns the string "Error" by default or the value contained in the `Error.message`
		property, if defined.
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
