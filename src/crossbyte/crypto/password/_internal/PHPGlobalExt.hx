package crossbyte.crypto.password._internal;

import haxe.extern.EitherType;
import php.NativeArray;
import php.NativeAssocArray;

@:phpGlobal
extern class PHPGlobalExt {
	static function password_hash(password:String, algo:EitherType<String, Int>, ?options:NativeAssocArray<Dynamic>):String;

	static function password_verify(password:String, hash:String):Bool;

	static function password_needs_rehash(hash:String, algo:EitherType<String, Int>, ?options:NativeAssocArray<Dynamic>):Bool;

	static function password_get_info(hash:String):NativeArray;

	static var PASSWORD_BCRYPT:String;
}
