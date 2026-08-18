package crossbyte._internal.http;

import haxe.io.Path;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.config.RewriteRule;
import crossbyte.http.config.RewriteCondition;
import crossbyte.http.config.RewriteConditionType;
import crossbyte.http.config.RewriteFlag;
import haxe.ds.StringMap;
#if (cpp || neko || hl || java || jvm)
import sys.thread.Tls;
#end

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

		for (c in cfg.tryFiles) {
			// `$uri` and `$uri/` are already settled: decide() opens by
			// testing both against the request path and returns if either
			// resolves, so reaching here means both have already failed.
			// Testing them again costs two filesystem probes per request and
			// cannot reach a different answer.
			if (c == "$uri" || c == "$uri/") {
				continue;
			}

			if (isFile(cfg, c)) {
				return d(c, false, true, q, false);
			}

			var idx:String = dirIndex(cfg, c);
			if (idx != null) {
				return d(idx, false, true, q, false);
			}
		}

		return null;
	}

	@:noCompletion public static inline function isPhpPath(p:String):Bool {
		return p != null && p.toLowerCase().endsWith(".php");
	}

	@:noCompletion public static function reMatch(pat:String, text:String, nocase:Bool):Bool {
		return __compile(pat, nocase).match(text);
	}

	@:noCompletion private static inline function d(fp:String, php:Bool, st:Bool, q:String, keep:Bool):Decision
		return {
			finalPath: fp,
			toPHP: php,
			isStatic: st,
			query: q,
			preserveURI: keep
		};

	/**
	 * `p` arrives percent-decoded exactly once by the request handler.
	 * Decoding it again here is not hygiene but corruption: a path whose
	 * single decode legitimately contains `+` or `%` — `/a+b.html`, or
	 * `/100%.html` from `/100%25.html` — would be form-decoded a second
	 * time and made to name a different file. Double-encoded traversal
	 * needs no second decode to stay caught: `%252e` decodes once to the
	 * literal text `%2e`, which no filesystem reads as a dot.
	 */
	@:noCompletion public static function normalize(p:String):String {
		var u:String = (p == null || p == "") ? "/" : p;
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

	/**
	 * Expands `$1` to `$9` in `target` with what `pat` captured from `text`.
	 *
	 * A single left-to-right pass rather than one `String.replace` per group,
	 * because a replace loop reprocesses text it has already written: a
	 * segment captured into `$1` whose own value contained `$2` had that
	 * `$2` substituted by the next iteration, letting the request rather than
	 * the rule author decide part of the rewritten target.
	 *
	 * `$0`, and `$10` upwards, are not groups. That matches mod_rewrite,
	 * where `$10` reads as `$1` followed by a literal `0`. A group the
	 * pattern never captured is left as written.
	 */
	@:noCompletion public static function backrefs(pat:String, text:String, target:String, nocase:Bool):String {
		var re:EReg = __compile(pat, nocase);

		if (!re.match(text)) {
			return target;
		}

		var out:StringBuf = new StringBuf();
		var pos:Int = 0;
		var length:Int = target.length;

		// Runs between markers are copied whole rather than a character at a
		// time, so a target carrying non-ASCII text is never taken apart.
		while (pos < length) {
			var marker:Int = target.indexOf("$", pos);

			if (marker < 0) {
				out.addSub(target, pos, length - pos);
				break;
			}

			var group:Int = marker + 1 < length ? target.charCodeAt(marker + 1) - "0".code : -1;
			var value:String = null;

			if (group >= 1 && group <= 9) {
				try {
					value = re.matched(group);
				} catch (_:Dynamic) {
					value = null;
				}
			}

			if (value == null) {
				// Not a group reference, or a group this pattern never
				// captured: the "$" stands as written.
				out.addSub(target, pos, marker - pos + 1);
				pos = marker + 1;
				continue;
			}

			out.addSub(target, pos, marker - pos);
			out.add(value);
			pos = marker + 2;
		}

		return out.toString();
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
					var re:EReg = __compile(c.pattern, true);
					re.match(method);
				case RewriteConditionType.Header:
					var v:String = headers != null ? headers.get(c.key) : null;
					var re:EReg = __compile(c.pattern, true);
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

	/**
	 * Compiled patterns, reused across requests.
	 *
	 * Every rule otherwise costs one `EReg` construction per request, and a
	 * rule that matches costs two, since `backrefs` recompiles the pattern it
	 * was just matched against. Patterns come from configuration, so the
	 * working set is small and fixed, while compiling them is the most
	 * expensive thing on this path.
	 *
	 * Held per thread rather than shared. An `EReg` carries the result of its
	 * last `match()`, so two runtime threads serving requests through one
	 * cached instance would read each other's captures.
	 */
	#if (cpp || neko || hl || java || jvm)
	@:noCompletion private static final __patterns:Tls<PatternCache> = new Tls();
	#else
	@:noCompletion private static var __patterns:PatternCache;
	#end

	/**
	 * Bounds the cache. Configuration supplies a fixed set far under this,
	 * but `reMatch` and `backrefs` are reachable with caller-supplied
	 * patterns, and dropping the cache is cheaper than growing it for good.
	 */
	@:noCompletion private static inline var PATTERN_LIMIT:Int = 256;

	@:noCompletion private static function __compile(pattern:String, nocase:Bool):EReg {
		var cache:PatternCache = #if (cpp || neko || hl || java || jvm) __patterns.value #else __patterns #end;

		if (cache == null) {
			cache = new PatternCache();
			#if (cpp || neko || hl || java || jvm)
			__patterns.value = cache;
			#else
			__patterns = cache;
			#end
		}

		// Two maps rather than one keyed by pattern-plus-flag: the same source
		// pattern compiled with and without `NC` is two different regular
		// expressions, and building a composite key would allocate a string
		// per rule per request, which is most of what this cache is here to
		// avoid.
		var entries:StringMap<EReg> = nocase ? cache.insensitive : cache.sensitive;
		var compiled:EReg = entries.get(pattern);

		if (compiled != null) {
			return compiled;
		}

		compiled = new EReg(pattern, nocase ? "i" : "");

		if (cache.size >= PATTERN_LIMIT) {
			cache.sensitive = new StringMap<EReg>();
			cache.insensitive = new StringMap<EReg>();
			cache.size = 0;
			entries = nocase ? cache.insensitive : cache.sensitive;
		}

		entries.set(pattern, compiled);
		cache.size++;

		return compiled;
	}
}

typedef Decision = {
	var finalPath:String;
	var toPHP:Bool;
	var isStatic:Bool;
	var query:String;
	var preserveURI:Bool;
}

/**
 * One thread's compiled patterns, with the entry count carried alongside so
 * the limit check does not have to walk the map on every miss.
 */
private class PatternCache {
	public var sensitive:StringMap<EReg> = new StringMap<EReg>();
	public var insensitive:StringMap<EReg> = new StringMap<EReg>();
	public var size:Int = 0;

	public function new() {}
}
