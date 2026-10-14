package crossbyte.auth;

import crossbyte.errors.ArgumentError;
import utest.Assert;

/**
	`Secret.resolve`: `env:` and `file:` references, and a value written as it
	is. Runs on every target, PHP included; a browser has neither, and says so.
**/
class SecretTest extends utest.Test {
	public function testAPlainValueIsItself():Void {
		Assert.equals("s3cr3t", Secret.resolve("s3cr3t"));
		Assert.equals(" padded ", Secret.resolve(" padded "));
	}

	public function testABlankOrNullReferenceIsRefused():Void {
		Assert.raises(() -> Secret.resolve(null), ArgumentError);
		Assert.raises(() -> Secret.resolve(""), ArgumentError);
		Assert.raises(() -> Secret.resolve("  \t "), ArgumentError);
		Assert.raises(() -> Secret.resolve("env:"), ArgumentError);
		Assert.raises(() -> Secret.resolve("file:"), ArgumentError);
	}

	#if (js && !nodejs)
	public function testABrowserHasNoEnvironmentOrFiles():Void {
		Assert.raises(() -> Secret.resolve("env:TOKEN_KEY"), crossbyte.errors.IllegalOperationError);
		Assert.raises(() -> Secret.resolve("file:/run/secrets/token_key"), crossbyte.errors.IllegalOperationError);
	}
	#else
	public function testAnEnvironmentVariableIsRead():Void {
		#if jvm
		// Sys.putEnv throws on the jvm, so a variable every system has stands in.
		var path:String = Sys.getEnv("PATH");
		Assert.notNull(path);
		Assert.equals(path, Secret.resolve("env:PATH"));
		#else
		Sys.putEnv("CROSSBYTE_SECRET_TEST", "from-the-environment ");
		Assert.equals("from-the-environment ", Secret.resolve("env:CROSSBYTE_SECRET_TEST"));
		#end
	}

	public function testAMissingVariableIsAnErrorThatNamesIt():Void {
		var message:String = null;
		try {
			Secret.resolve("env:CROSSBYTE_SECRET_TEST_NEVER_SET");
		} catch (e:ArgumentError) {
			message = e.message;
		}
		Assert.notNull(message);
		Assert.isTrue(message != null && message.indexOf("CROSSBYTE_SECRET_TEST_NEVER_SET") >= 0, message);
	}

	#if !jvm
	public function testABlankVariableIsAnError():Void {
		Sys.putEnv("CROSSBYTE_SECRET_TEST_BLANK", "  ");
		Assert.raises(() -> Secret.resolve("env:CROSSBYTE_SECRET_TEST_BLANK"), ArgumentError);
	}
	#end

	public function testAFileIsReadWithItsTrailingLineBreaksTakenOff():Void {
		var lf:String = __write("token-key\n");
		var crlf:String = __write("token-key\r\n\r\n");
		var none:String = __write("token-key");
		var inner:String = __write("line one\nline two \t\n");

		Assert.equals("token-key", Secret.resolve("file:" + lf));
		Assert.equals("token-key", Secret.resolve("file:" + crlf));
		Assert.equals("token-key", Secret.resolve("file:" + none));
		// Only the line breaks at the end: a break inside and a trailing tab
		// or space are part of the secret.
		Assert.equals("line one\nline two \t", Secret.resolve("file:" + inner));

		for (path in [lf, crlf, none, inner]) {
			sys.FileSystem.deleteFile(path);
		}
	}

	public function testAMissingOrEmptyFileIsAnErrorThatNamesItButNotTheValue():Void {
		var empty:String = __write("\n");
		var missing:String = empty + ".absent";

		var messages:Array<String> = [];
		for (ref in ["file:" + empty, "file:" + missing]) {
			try {
				Secret.resolve(ref);
				messages.push(null);
			} catch (e:ArgumentError) {
				messages.push(e.message);
			}
		}

		Assert.isTrue(messages[0] != null && messages[0].indexOf(empty) >= 0, messages[0]);
		Assert.isTrue(messages[1] != null && messages[1].indexOf(missing) >= 0, messages[1]);
		sys.FileSystem.deleteFile(empty);

		// A directory is not a secret either.
		Assert.raises(() -> Secret.resolve("file:" + __directory()), ArgumentError);
	}

	private static var __count:Int = 0;

	private function __write(content:String):String {
		var path:String = haxe.io.Path.join([__directory(), 'crossbyte-secret-${Std.random(1000000)}-${__count++}.txt']);
		sys.io.File.saveContent(path, content);
		return path;
	}

	private function __directory():String {
		for (candidate in [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"]) {
			if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
				return candidate;
			}
		}
		return ".";
	}
	#end
}
