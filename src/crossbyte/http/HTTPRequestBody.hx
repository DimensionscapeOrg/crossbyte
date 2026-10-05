package crossbyte.http;

import haxe.ds.Either;
import haxe.io.Bytes;

/**
	A request body as an `HTTPBackend` is handed it (`HTTPRequestContext.data`):
	text, sent as UTF-8, or bytes, sent as they are.

	Either converts to one, so a body is given as before:

	```haxe
	context.data = "name=value";      // text
	context.data = haxe.io.Bytes.alloc(16); // bytes
	```

	A backend reads `toBytes()` for what goes on the wire, and `text` or
	`isText` where it matters which it was, for a default `Content-Type`,
	say. This was `Dynamic`, holding a `String` or `Bytes`, which every backend
	had to tell apart with `Std.isOfType` and a third case for anything else.
**/
abstract HTTPRequestBody(Either<String, Bytes>) {
	private inline function new(value:Either<String, Bytes>) {
		this = value;
	}

	/** A body of text, sent as UTF-8; null for null, as no body. */
	@:from public static function fromString(text:String):HTTPRequestBody {
		return text == null ? null : new HTTPRequestBody(Left(text));
	}

	/**
		A body of bytes, sent as they are; null for null, as no body.

		The bytes themselves, not a copy: the body is read when the request
		goes out, and again for a redirect that keeps it. The client makes
		one from a copy it took when the load began (`URLLoader.load`), so a
		caller's bytes are its own again once `load` has returned; code that
		makes a context itself keeps its bytes unchanged until the request
		is done.
	**/
	@:from public static function fromBytes(bytes:Bytes):HTTPRequestBody {
		return bytes == null ? null : new HTTPRequestBody(Right(bytes));
	}

	/** Whether the body was given as text. */
	public var isText(get, never):Bool;

	private function get_isText():Bool {
		return switch (this) {
			case Left(_): true;
			case Right(_): false;
		}
	}

	/** The text the body was given as, or null when it was given as bytes. */
	public var text(get, never):Null<String>;

	private function get_text():Null<String> {
		return switch (this) {
			case Left(text): text;
			case Right(_): null;
		}
	}

	/** What goes on the wire: the text as UTF-8, or the bytes as given. */
	public function toBytes():Bytes {
		return switch (this) {
			case Left(text): crossbyte._internal.Utf8.bytesOf(text);
			case Right(bytes): bytes;
		}
	}
}
