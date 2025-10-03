package crossbyte._internal.http;

import haxe.io.Path;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.config.RewriteRule;
import crossbyte.http.config.RewriteCondition;
import crossbyte.http.config.RewriteConditionType;
import crossbyte.http.config.RewriteFlag;
import haxe.ds.StringMap;

using StringTools;

class RewriteEngine {
	public static function decide(cfg:HTTPServerConfig, reqPath:String, reqQuery:String, method:String, headers:StringMap<String>):Decision {
		var orig:String = normalize(reqPath);
		var q:String = reqQuery;

		if (isFile(cfg, orig)) {
			return d(orig, false, true, q, false);
		}

		var idx0:String = dirIndex(cfg, orig);
		if (idx0 != null) {
			return d(idx0, false, true, q, false);
		}

		var working:String = orig;
		for (r in cfg.rewrites) {
			if (!reMatch(r.pattern, working, has(r, RewriteFlag.NC))) {
				continue;
			}

			if (!condsPass(r.conditions, cfg, working, method, headers)) {
				continue;
			}

			var needsBackrefs:Bool = (r.target.indexOf("$") >= 0);
			var expanded:String = needsBackrefs ? backrefs(r.pattern, working, r.target, has(r, RewriteFlag.NC)) : r.target;
			var tPath:String = stripQuery(expanded);
			var tQ:String = extractQuery(expanded);
			q = has(r, RewriteFlag.QSA) ? merge(q, tQ) : tQ;

			if (has(r, RewriteFlag.PHP)) {
				return d(tPath, true, false, q, true);
			}

			if (has(r, RewriteFlag.PT)) {
				working = tPath;
				if (isFile(cfg, working)) {
					return d(working, false, true, q, false);
				}
				var idxPT:String = dirIndex(cfg, working);
				if (idxPT != null) {
					return d(idxPT, false, true, q, false);
				}
				if (has(r, RewriteFlag.L)) {
					break;
				}

				continue;
			}

			if (isFile(cfg, tPath)) {
				return d(tPath, false, true, q, false);
			}

			if (has(r, RewriteFlag.L)) {
				break;
			}
		}

		for (c in cfg.tryFiles)
			switch (c) {
				case "$uri":
					if (isFile(cfg, orig)) {
						return d(orig, false, true, q, false);
					}
				case "$uri/":
					var idx1:String = dirIndex(cfg, orig);
					if (idx1 != null) {
						return d(idx1, false, true, q, false);
					}
				default:
					var literal:String = c;
					if (isFile(cfg, literal)) {
						return d(literal, false, true, q, false);
					}

					var idx2:String = dirIndex(cfg, literal);
					if (idx2 != null) {
						return d(idx2, false, true, q, false);
					}
			}
		return null;
	}

	@:noCompletion public static inline function isPhpPath(p:String):Bool {
		return p != null && p.toLowerCase().endsWith(".php");
	}

	@:noCompletion public static function reMatch(pat:String, text:String, nocase:Bool):Bool {
		var re:EReg = new EReg(pat, nocase ? "i" : "");
		return re.match(text);
	}

	@:noCompletion private static inline function d(fp:String, php:Bool, st:Bool, q:String, keep:Bool):Decision
		return {
			finalPath: fp,
			toPHP: php,
			isStatic: st,
			query: q,
			preserveURI: keep
		};

	@:noCompletion public static function normalize(p:String):String {
		var u:String = StringTools.urlDecode((p == null || p == "") ? "/" : p);
		u = ~/(\/+)/g.replace(u.replace("\\", "/"), "/");

		if (!u.startsWith("/")) {
			u = "/" + u;
		}

		if (u.indexOf("..") >= 0) {
			throw "403";
		}

		return u;
	}

	@:noCompletion public static function abs(cfg:HTTPServerConfig, web:String):String {
		var root:String = Path.normalize(cfg.rootDirectory.nativePath);
		var rootSlash:String = root.endsWith("/") ? root : root + "/";
		var rel:String = web.startsWith("/") ? web.substr(1) : web;
		var a:String = Path.normalize(rootSlash + rel);

		if (!(a == root || a.startsWith(rootSlash))) {
			throw "403";
		}

		return a;
	}

	@:noCompletion public static inline function isFile(cfg:HTTPServerConfig, web:String):Bool {
		var a:String = abs(cfg, web);

		return sys.FileSystem.exists(a) && !sys.FileSystem.isDirectory(a);
	}

	@:noCompletion public static function dirIndex(cfg:HTTPServerConfig, dirWeb:String):Null<String> {
		var a:String = abs(cfg, dirWeb);
		if (!sys.FileSystem.exists(a) || !sys.FileSystem.isDirectory(a)) {
			return null;
		}

		for (i in cfg.directoryIndex) {
			var p:String = Path.join([a, i]);

			if (sys.FileSystem.exists(p) && !sys.FileSystem.isDirectory(p)) {
				var w:String = (dirWeb.endsWith("/") ? dirWeb : dirWeb + "/") + i;
				return w;
			}
		}

		return null;
	}

	@:noCompletion public static inline function stripQuery(s:String):String {
		var i:Int = s.indexOf("?");

		return i >= 0 ? s.substr(0, i) : s;
	}

	@:noCompletion public static inline function extractQuery(s:String):String {
		var i:Int = s.indexOf("?");

		return i >= 0 ? s.substr(i + 1) : "";
	}

	@:noCompletion public static inline function merge(a:String, b:String):String {
		if (a == null || a == "") {
			return b;
		}

		if (b == null || b == "") {
			return a;
		}

		return a + "&" + b;
	}

	@:noCompletion public static inline function has(r:RewriteRule, f:RewriteFlag):Bool {
		return r.flags != null && r.flags.indexOf(f) != -1;
	}

	@:noCompletion public static function backrefs(pat:String, text:String, target:String, nocase:Bool):String {
		var re:EReg = new EReg((nocase ? "(?i)" : "") + pat, "");
		if (!re.match(text)) {
			return target;
		}

		var out:String = target;
		for (i in 1...10) {
			var m:String = null;
            
			try {
				m = re.matched(i);
			} catch (_:Dynamic) {
				m = null;
			}
			if (m != null)
				out = out.replace("$" + i, m);
		}

		return out;
	}

	static function condsPass(conds:Array<RewriteCondition>, cfg:HTTPServerConfig, working:String, method:String, headers:Map<String, String>):Bool {
		if (conds == null || conds.length == 0) {
			return true;
		}

		for (c in conds) {
			var ok:Bool = switch (c.type) {
				case RewriteConditionType.FileExists:
					isFile(cfg, working);
				case RewriteConditionType.DirExists: final a = abs(cfg, working); sys.FileSystem.exists(a) && sys.FileSystem.isDirectory(a);
				case RewriteConditionType.Method:
					var re:EReg = new EReg(c.pattern, "i");
					re.match(method);
				case RewriteConditionType.Header:
					var v:String = headers != null ? headers.get(c.key) : null;
					var re:EReg = new EReg(c.pattern, "i");
					re.match(v == null ? "" : v);
			}

			if (c.negate) {
				ok = !ok;
			}
			if (!ok) {
				return false;
			}
		}

		return true;
	}
}

typedef Decision = {
	var finalPath:String;
	var toPHP:Bool;
	var isStatic:Bool;
	var query:String;
	var preserveURI:Bool;
}
