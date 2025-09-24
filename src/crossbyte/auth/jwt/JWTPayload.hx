package crossbyte.auth.jwt;

@:structInit
abstract JWTPayload(JWTPayloadData) {
	public var subject(get, set):String;
	public var name(get, set):String;
	public var issuedAt(get, set):Int;
	public var expiresAt(get, set):Int;
	public var notBeforeTime(get, set):Null<Int>;
	public var issuer(get, set):String;
	public var audience(get, set):Dynamic;
	public var tokenId(get, set):String;

	@:noCompletion private inline function get_subject():String {
		return this.sub;
	}

	@:noCompletion private inline function set_subject(v:String):String {
		return this.sub = v;
	}

	@:noCompletion private inline function get_name():String {
		return this.name;
	}

	@:noCompletion private inline function set_name(v:String):String {
		return this.name = v;
	}

	@:noCompletion private inline function get_issuedAt():Int {
		return this.iat;
	}

	@:noCompletion private inline function set_issuedAt(v:Int):Int {
		return this.iat = v;
	}

	@:noCompletion private inline function get_expiresAt():Int {
		return this.exp;
	}

	@:noCompletion private inline function set_expiresAt(v:Int):Int {
		return this.exp = v;
	}

	@:noCompletion private inline function get_notBeforeTime():Null<Int> {
		return this.nbf;
	}

	@:noCompletion private inline function set_notBeforeTime(v:Null<Int>):Null<Int> {
		return this.nbf = v;
	}

	@:noCompletion private inline function get_issuer():String {
		return this.iss;
	}

	@:noCompletion private inline function set_issuer(v:String):String {
		return this.iss = v;
	}

	@:noCompletion private inline function get_audience():String {
		return this.aud;
	}

	@:noCompletion private inline function set_audience(v:Dynamic):Dynamic {
		return this.aud = v;
	}

	@:noCompletion private inline function get_tokenId():String {
		return this.jti;
	}

	@:noCompletion private inline function set_tokenId(v:String) {
		return this.jti = v;
	}

	public inline function new(d:JWTPayloadData) {
		this = d;
	}

	@:to public inline function toData():JWTPayloadData {
		return this;
	}

	@:from public static inline function ofData(d:JWTPayloadData):JWTPayload {
		return new JWTPayload(d);
	}
}

typedef JWTPayloadData = {
	var sub:String;
	@:optional var name:String;
	var iat:Int;
	var exp:Int;
	@:optional var nbf:Int;
	@:optional var iss:String;
	@:optional var aud:Dynamic;
	@:optional var jti:String;
}
