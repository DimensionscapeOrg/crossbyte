package crossbyte.auth;

import crossbyte.errors.ArgumentError;

/**
 * Shared secret material used by authentication helpers such as JWT signers.
 * Written as an object literal, `{key: "2026-09", secret: value}`, with `key`
 * left out where there is one secret.
 *
 * `Secret.resolve` reads a secret named in configuration from where it is
 * kept, so the configuration itself never has to hold it.
 */
@:structInit
final class Secret {
	/** Optional key identifier used to select a specific secret. */
	public var key:Null<String> = null;

	/** Secret bytes represented as a string payload. */
	public var secret:String;

	/**
		The secret `ref` names:

		- `env:NAME`, the value of the environment variable `NAME`, as it is;
		- `file:PATH`, the contents of the file at `PATH` (relative to the
		  working directory), with any line breaks at its end taken off, as a
		  Docker or Kubernetes secret mounted as a file
		  (`file:/run/secrets/token_key`) is usually written with one;
		- anything else, `ref` itself, as it is: a value written into the
		  configuration directly, which a development setup may want. Keep real
		  secrets out of files that are checked in, and name them instead.

		```haxe
		var key:String = Secret.resolve("env:TOKEN_KEY");
		var password:String = Secret.resolve("file:/run/secrets/db_password");
		```

		A missing secret is an error, never a default: a service signing tokens
		with an empty key would accept tokens anyone can make.

		@throws ArgumentError When `ref` is null, the variable is not set, the
		        file cannot be read, or what it names is empty or only
		        whitespace. The message names the variable or file, never the
		        value.
		@throws crossbyte.errors.IllegalOperationError In a browser, for
		        `env:` and `file:`, which it has no environment or files for.
	**/
	public static function resolve(ref:String):String {
		if (ref == null) {
			throw new ArgumentError("A secret reference must not be null.");
		}

		var value:Null<String>;
		var source:String;
		if (StringTools.startsWith(ref, "env:")) {
			var name:String = ref.substr(4);
			if (name == "") {
				throw new ArgumentError('Secret reference "env:" names no variable.');
			}
			source = 'environment variable $name';
			value = __environment(name);
			if (value == null) {
				throw new ArgumentError('The secret in environment variable $name is not set.');
			}
		} else if (StringTools.startsWith(ref, "file:")) {
			var path:String = ref.substr(5);
			if (path == "") {
				throw new ArgumentError('Secret reference "file:" names no file.');
			}
			source = 'file $path';
			value = __trimLineEnds(__file(path));
		} else {
			source = "the configuration";
			value = ref;
		}

		if (StringTools.trim(value) == "") {
			throw new ArgumentError('The secret in $source is empty.');
		}
		return value;
	}

	@:noCompletion private static function __environment(name:String):Null<String> {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no environment variables to read a secret from.");
		#else
		return Sys.getEnv(name);
		#end
	}

	@:noCompletion private static function __file(path:String):String {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("A browser has no files to read a secret from.");
		#else
		if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) {
			throw new ArgumentError('The secret file $path does not exist.');
		}
		try {
			return sys.io.File.getContent(path);
		} catch (_:Dynamic) {
			throw new ArgumentError('The secret file $path could not be read.');
		}
		#end
	}

	// The line breaks at the end of `text`, and only those: a secret may end
	// in a space or a tab on purpose, and echo or an editor adds the break.
	@:noCompletion private static function __trimLineEnds(text:String):String {
		var end:Int = text.length;
		while (end > 0) {
			var code:Int = StringTools.fastCodeAt(text, end - 1);
			if (code != "\n".code && code != "\r".code) {
				break;
			}
			end--;
		}
		return end == text.length ? text : text.substr(0, end);
	}
}
