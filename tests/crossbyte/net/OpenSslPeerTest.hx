package crossbyte.net;

#if !(js && !nodejs)
#if (cpp || hl || neko || java || jvm || nodejs || eval)
import crossbyte.http.HTTPVersion;
import crossbyte.net.TlsRefusalSupport.TlsCase;
import utest.Assert;
#end
import utest.Async;

/**
	CrossByte's TLS against OpenSSL's own command line, `openssl s_server`
	and `openssl s_client`, each run beside the test as a process of its
	own.

	A peer that can offer nothing newer than TLS 1.0 or 1.1 is refused, by a
	secure `Socket` dialling one and by a TLS `ServerSocket` one dials:
	both versions are long broken, and natively, on the jvm, on Node and on
	neko the TLS underneath leaves them out unless told otherwise. Natively
	that was the one place it was checked, against Node. Each sits beside the
	same peer offering TLS 1.2, which has to be let in. The old versions are
	offered at `SECLEVEL=0`, without which OpenSSL 3 will not speak them.

	Not on HashLink or the interpreter, whose TLS still negotiates TLS 1.0
	and 1.1, either way, and gives a program no way to set the lowest
	version it takes.

	And on eval, which cannot run a TLS server of its own, a `Socket` and an
	`https` `URLLoader` dialling `s_server` are held to the certificates
	`CertificateExpiryTest` and `CertificateTrustTest` hold every other
	target's clients to.

	Where there is no `openssl`, or it was built without the old versions,
	the cases warn and do not run.
**/
class OpenSslPeerTest extends utest.Test {
	#if (cpp || neko || java || jvm || nodejs)
	/** A secure `Socket` refuses a server offering nothing newer than TLS 1.1. **/
	@:timeout(60000)
	public function testASocketRefusesAServerOfferingOnlyAnOldVersion(async:Async):Void {
		var authority:Certificate = Certificate.fromPem(CertificateExpiryTest.AUTHORITY);
		__eachVersion(function(version, next) {
			OpenSslProcess.serve(version.flags, CertificateExpiryTest.ISSUED, CertificateExpiryTest.DATED_KEY, function(server) {
				if (server == null) {
					Assert.warn('no openssl on this machine that serves ${version.name}; the case did not run');
					next();
					return;
				}
				TlsRefusalSupport.dialSocket("127.0.0.1", server.port, authority, null, function(outcome) {
					server.stop();
					if (version.accepted) {
						Assert.isTrue(outcome.connected, 'a Socket refused a server offering ${version.name}: ' + outcome.failure);
					} else {
						Assert.isFalse(outcome.connected, 'a Socket connected to a server offering nothing newer than ${version.name}');
						Assert.notNull(outcome.failure, 'a Socket to a server offering nothing newer than ${version.name} neither connected nor failed');
					}
					next();
				});
			});
		}, () -> async.done());
	}
	#end

	#if (cpp || neko || java || jvm || nodejs)
	/**
		A TLS `ServerSocket` refuses a client offering nothing newer than TLS
		1.1: it never dispatches the connection. Not on eval, which cannot run
		a TLS server.
	**/
	@:timeout(60000)
	public function testAServerRefusesAClientOfferingOnlyAnOldVersion(async:Async):Void {
		var issued:Certificate = Certificate.fromPem(CertificateExpiryTest.ISSUED);
		var key:Key = Key.fromPem(CertificateExpiryTest.DATED_KEY);
		__eachVersion(function(version, next) {
			TlsRefusalSupport.serveTls(issued, key, null, function(server) {
				OpenSslProcess.dial(server.port, version.flags, function(client) {
					if (client == null) {
						server.close();
						Assert.warn('no openssl on this machine that offers ${version.name}; the case did not run');
						next();
						return;
					}
					NetPump.until(() -> server.accepted() > 0 || server.failures() >= 1 || client.ended(), 10.0, function(_) {
						// A little longer, so a connection let in late is counted.
						NetPump.wait(0.2, function() {
							var accepted:Int = server.accepted();
							client.stop();
							server.close();
							if (version.accepted) {
								Assert.equals(1, accepted, 'a server refused a client offering ${version.name}');
							} else {
								Assert.equals(0, accepted, 'a server let in a client offering nothing newer than ${version.name}');
							}
							next();
						});
					});
				});
			});
		}, () -> async.done());
	}
	#end

	#if eval
	/**
		On eval, a secure `Socket` dialling `s_server` refuses each
		certificate the other targets' clients refuse, and takes each they
		take.
	**/
	@:timeout(120000)
	public function testASocketRefusesWhatNothingVouchesFor(async:Async):Void {
		__eachServed(function(tried, port, then) {
			TlsRefusalSupport.dialSocket(tried.host != null ? tried.host : "127.0.0.1", port, tried.authority, null, function(outcome) {
				TlsRefusalSupport.judge("a Socket", tried, outcome, null);
				then();
			});
		}, () -> async.done());
	}

	/** And an `https` `URLLoader` the same. **/
	@:timeout(120000)
	public function testAnHttpsLoadRefusesWhatNothingVouchesFor(async:Async):Void {
		__eachServed(function(tried, port, then) {
			var host:String = tried.host != null ? tried.host : "127.0.0.1";
			TlsRefusalSupport.load('https://$host:$port/', tried.authority, HTTPVersion.HTTP_1_1, null, function(outcome) {
				TlsRefusalSupport.judge("an https URLLoader", tried, outcome, null);
				then();
			});
		}, () -> {
			crossbyte._internal.http.HttpConnectionPool.clear();
			async.done();
		});
	}

	/**
		`dial` for each case of `CertificateExpiryTest` and `CertificateTrustTest`,
		with `s_server` presenting its certificate; then `done`.
	**/
	private static function __eachServed(dial:(TlsCase, Int, Void->Void) -> Void, done:Void->Void):Void {
		var cases:Array<TlsCase> = (@:privateAccess CertificateExpiryTest.__cases()).concat(@:privateAccess CertificateTrustTest.__cases());
		function next(index:Int):Void {
			if (index >= cases.length) {
				done();
				return;
			}
			var tried:TlsCase = cases[index];
			OpenSslProcess.serve([], tried.certificatePem, tried.keyPem, function(server) {
				if (server == null) {
					Assert.warn("no openssl on this machine to serve with; the case did not run");
					done();
					return;
				}
				dial(tried, server.port, function() {
					server.stop();
					next(index + 1);
				});
			});
		}
		next(0);
	}
	#end

	#if (cpp || neko || java || jvm || nodejs)
	/** TLS 1.2, which is let in, then TLS 1.1 and 1.0, which are not. **/
	private static function __eachVersion(each:(OldVersion, Void->Void) -> Void, done:Void->Void):Void {
		var versions:Array<OldVersion> = [
			{name: "TLS 1.2", flags: ["-tls1_2"], accepted: true},
			{name: "TLS 1.1", flags: ["-tls1_1", "-cipher", "DEFAULT@SECLEVEL=0"], accepted: false},
			{name: "TLS 1.0", flags: ["-tls1", "-cipher", "DEFAULT@SECLEVEL=0"], accepted: false}
		];
		function next(index:Int):Void {
			if (index >= versions.length) {
				done();
				return;
			}
			each(versions[index], () -> next(index + 1));
		}
		next(0);
	}
	#end
}

#if (cpp || hl || neko || java || jvm || nodejs || eval)
private typedef OldVersion = {
	var name:String;
	var flags:Array<String>;
	var accepted:Bool;
}

/**
	An `openssl s_server` or `s_client`, run for one case and stopped after
	it. A server listens on a port the system picks, read back from what it
	prints, and answers a request as `-www` does; its certificate and key
	are written to files for it, removed when it stops.
**/
private class OpenSslProcess {
	/** The port a server listens on. **/
	public var port(default, null):Int = 0;

	private var __files:Array<String> = [];
	private var __directory:Null<String> = null;
	private var __ended:Bool = false;
	#if nodejs
	private var __child:Dynamic = null;
	#else
	private var __process:Null<sys.io.Process> = null;
	#end

	private function new() {}

	/**
		`s_server` with `flags`, presenting `certificatePem`, and `then` once
		it listens; `then` with null when it would not.
	**/
	public static function serve(flags:Array<String>, certificatePem:String, keyPem:String, then:Null<OpenSslProcess>->Void):Void {
		var server = new OpenSslProcess();
		var certificatePath:String;
		var keyPath:String;
		try {
			server.__directory = haxe.io.Path.join([__tempDirectory(), "crossbyte-openssl-" + Std.random(0x3FFFFFFF)]);
			sys.FileSystem.createDirectory(server.__directory);
			certificatePath = server.__file("cert.pem", certificatePem);
			keyPath = server.__file("key.pem", keyPem);
		} catch (_:Dynamic) {
			server.stop();
			then(null);
			return;
		}
		var args:Array<String> = ["s_server", "-accept", "127.0.0.1:0", "-cert", certificatePath, "-key", keyPath, "-www"].concat(flags);

		#if nodejs
		var settled:Bool = false;
		function settle(listening:Bool):Void {
			if (settled) {
				return;
			}
			settled = true;
			if (!listening) {
				server.stop();
			}
			then(listening ? server : null);
		}
		var printed:String = "";
		var child:Dynamic = js.Lib.require("child_process").spawn("openssl", args, {stdio: ["ignore", "pipe", "ignore"]});
		server.__child = child;
		child.on("error", _ -> settle(false));
		child.on("exit", function(_) {
			server.__ended = true;
			settle(false);
		});
		child.stdout.on("data", function(chunk:Dynamic) {
			printed += Std.string(chunk);
			var accept = ~/ACCEPT [^:\s]+:([0-9]+)/;
			if (accept.match(printed)) {
				server.port = Std.parseInt(accept.matched(1));
				settle(true);
			}
		});
		js.Node.setTimeout(() -> settle(false), 10000);
		#else
		try {
			var process = new sys.io.Process("openssl", args);
			server.__process = process;
			var accept = ~/ACCEPT [^:\s]+:([0-9]+)/;
			while (server.port == 0) {
				var line:String = process.stdout.readLine();
				if (accept.match(line)) {
					server.port = Std.parseInt(accept.matched(1));
				}
			}
		} catch (_:Dynamic) {
			// No openssl, or one that would not start as asked: it said why
			// on its error output and ended.
			server.stop();
			then(null);
			return;
		}
		then(server);
		#end
	}

	/**
		`s_client` with `flags`, dialling `port` on 127.0.0.1, and `then` once
		it is under way; `then` with null when it could not be started.
	**/
	public static function dial(port:Int, flags:Array<String>, then:Null<OpenSslProcess>->Void):Void {
		var client = new OpenSslProcess();
		// Quiet, and so not ended by its input closing: it is stopped once
		// the server has decided.
		var args:Array<String> = ["s_client", "-connect", '127.0.0.1:$port', "-quiet"].concat(flags);
		#if nodejs
		var settled:Bool = false;
		var child:Dynamic = js.Lib.require("child_process").spawn("openssl", args, {stdio: ["pipe", "ignore", "ignore"]});
		client.__child = child;
		child.on("error", function(_) {
			client.__ended = true;
			if (!settled) {
				settled = true;
				then(null);
			}
		});
		child.on("exit", _ -> client.__ended = true);
		child.on("spawn", function() {
			if (!settled) {
				settled = true;
				then(client);
			}
		});
		#else
		try {
			client.__process = new sys.io.Process("openssl", args);
		} catch (_:Dynamic) {
			then(null);
			return;
		}
		then(client);
		#end
	}

	/** Whether the process has ended by itself, where that can be told. **/
	public function ended():Bool {
		#if nodejs
		return __ended;
		#else
		return false;
		#end
	}

	/** Ends the process, and removes its files. **/
	public function stop():Void {
		#if nodejs
		if (__child != null && !__ended) {
			try __child.kill() catch (_:Dynamic) {}
		}
		#else
		if (__process != null) {
			try __process.kill() catch (_:Dynamic) {}
			try __process.close() catch (_:Dynamic) {}
			__process = null;
		}
		#end
		for (path in __files) {
			try sys.FileSystem.deleteFile(path) catch (_:Dynamic) {}
		}
		__files = [];
		if (__directory != null) {
			try sys.FileSystem.deleteDirectory(__directory) catch (_:Dynamic) {}
			__directory = null;
		}
	}

	private function __file(name:String, content:String):String {
		var path:String = haxe.io.Path.join([__directory, name]);
		sys.io.File.saveContent(path, content);
		__files.push(path);
		return path;
	}

	private static function __tempDirectory():String {
		for (candidate in [Sys.getEnv("TEMP"), Sys.getEnv("TMP"), Sys.getEnv("TMPDIR"), "/tmp"]) {
			if (candidate != null && candidate != "" && sys.FileSystem.exists(candidate)) {
				return candidate;
			}
		}
		return ".";
	}
}
#end
#end
