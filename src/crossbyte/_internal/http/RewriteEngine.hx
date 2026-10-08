package crossbyte._internal.http;

// Not built for any JavaScript target (Node included, which has no threads): it belongs to the server-side HTTP stack, which needs a listening socket and a filesystem.
#if !(js && !nodejs)

import haxe.io.Path;
import crossbyte.http.HTTPServerConfig;
import crossbyte.http.config.RewriteRule;
import crossbyte.http.config.RewriteCondition;
import crossbyte.http.config.RewriteConditionType;
import crossbyte.http.config.RewriteFlag;
import haxe.ds.StringMap;
#if target.threaded
import sys.thread.Tls;
#end

using StringTools;

class RewriteEngine {
	/**
	 * Resolves a request path to a file, a directory index, a rewrite or
	 * nothing.
	 *
	 * The handler calls this only once middleware has let a request through,
	 * and each call costs filesystem lookups, so a request a route answered
	 * never pays for them. A path or rewrite target whose `..` steps climb
	 * above the root resolves to nothing, rather than throwing.
	 *
	 * A request naming an existing file or directory index is served it,
	 * unless a rule that asks about files (one with a `FileExists` or
	 * `DirExists` condition) applies first; every other rule is passed over
	 * for it, which is Apache's `RewriteCond !-f` written in for every rule
	 * that does not say otherwise.
	 */
	public static function decide(cfg:HTTPServerConfig, reqPath:String, reqQuery:String, method:String, headers:StringMap<String>,
			?seen:FileSeen):Decision {
		var orig:Null<String> = normalize(reqPath);
		if (orig == null) {
			return null;
		}
		var q:String = reqQuery;

		// What the request names as it stands: a file, or a directory's index;
		// with no rules that is the whole of it. Asked of the system once
		// (FileFacts), and what was found handed on with the decision, or
		// through `seen` when nothing was found, so the handler does not ask
		// again.
		var origFacts:FileFacts = __probe(cfg, orig);
		if (seen != null) {
			seen.path = orig;
			seen.facts = origFacts;
		}
		var named:Null<String> = null;
		var namedFacts:Null<FileFacts> = null;
		if (__isFile(cfg, orig, origFacts)) {
			named = orig;
			namedFacts = origFacts;
		} else {
			var index:Null<IndexMatch> = __indexOf(cfg, orig, origFacts);
			if (index != null) {
				named = index.web;
				namedFacts = index.facts;
			}
		}

		var working:String = orig;
		for (r in cfg.rewrites) {
			// A file the request names wins over a rule that does not ask
			// about files. One that does decides for itself, in its place.
			if (named != null && !asksAboutFiles(r)) {
				continue;
			}

			if (!reMatch(r.pattern, working, has(r, RewriteFlag.NC))) {
				continue;
			}

			if (!condsPass(r.conditions, cfg, working, method, headers)) {
				continue;
			}

			var needsBackrefs:Bool = (r.target.indexOf("$") >= 0);
			var expanded:String = needsBackrefs ? backrefs(r.pattern, working, r.target, has(r, RewriteFlag.NC)) : r.target;
			// Settled like the request path, so a target is contained and
			// spelled the way the rest of the server reads paths; a capture
			// can carry the request's own text into it.
			var tPath:Null<String> = normalize(stripQuery(expanded));
			if (tPath == null) {
				continue;
			}
			var tQ:String = extractQuery(expanded);
			q = has(r, RewriteFlag.QSA) ? merge(q, tQ) : tQ;

			if (has(r, RewriteFlag.PHP)) {
				return d(tPath, true, false, q, true);
			}

			if (has(r, RewriteFlag.PT)) {
				working = tPath;
				var workingFacts:FileFacts = __probe(cfg, working);
				if (__isFile(cfg, working, workingFacts)) {
					return d(working, false, true, q, false, workingFacts);
				}
				var idxPT:Null<IndexMatch> = __indexOf(cfg, working, workingFacts);
				if (idxPT != null) {
					return d(idxPT.web, false, true, q, false, idxPT.facts);
				}
				if (has(r, RewriteFlag.L)) {
					break;
				}

				continue;
			}

			var targetFacts:FileFacts = __probe(cfg, tPath);
			if (__isFile(cfg, tPath, targetFacts)) {
				return d(tPath, false, true, q, false, targetFacts);
			}

			if (has(r, RewriteFlag.L)) {
				break;
			}
		}

		if (named != null) {
			// No rule that asked took it elsewhere. The query is the request's:
			// a rule that matched and led nowhere does not change it.
			return d(named, false, true, reqQuery, false, namedFacts);
		}

		for (c in cfg.tryFiles) {
			// `$uri` and `$uri/` are already settled: decide() opens by
			// testing both against the request path, and reaching here means
			// both have failed. Testing them again costs two filesystem probes
			// per request and cannot reach a different answer.
			if (c == "$uri" || c == "$uri/") {
				continue;
			}

			// `$uri` in a later entry is the request path, as in nginx's
			// try_files: "$uri.html" serves /about from about.html. Settled
			// again, since a path joined to text is a new path.
			var entry:Null<String> = c.indexOf("$uri") >= 0 ? normalize(StringTools.replace(c, "$uri", orig)) : c;
			if (entry == null) {
				continue;
			}

			var entryFacts:FileFacts = __probe(cfg, entry);
			if (__isFile(cfg, entry, entryFacts)) {
				return d(entry, false, true, q, false, entryFacts);
			}

			var idx:Null<IndexMatch> = __indexOf(cfg, entry, entryFacts);
			if (idx != null) {
				return d(idx.web, false, true, q, false, idx.facts);
			}
		}

		return null;
	}

	/** Whether `rule` has a `FileExists` or `DirExists` condition, and so says for itself what an existing file means to it. */
	@:noCompletion public static function asksAboutFiles(rule:RewriteRule):Bool {
		var conditions:Null<Array<RewriteCondition>> = rule.conditions;
		if (conditions == null) {
			return false;
		}
		for (condition in conditions) {
			if (condition.type == RewriteConditionType.FileExists || condition.type == RewriteConditionType.DirExists) {
				return true;
			}
		}
		return false;
	}

	@:noCompletion public static inline function isPhpPath(p:String):Bool {
		return p != null && p.toLowerCase().endsWith(".php");
	}

	@:noCompletion public static function reMatch(pat:String, text:String, nocase:Bool):Bool {
		return __compile(pat, nocase).match(text);
	}

	@:noCompletion private static inline function d(fp:String, php:Bool, st:Bool, q:String, keep:Bool, ?facts:FileFacts):Decision {
		return new Decision(fp, php, st, q, keep, facts != null && facts.servable ? facts : null);
	}

	/**
	 * `HttpSyntax.normalizePath`: the request path's spelling settled, or
	 * null when its `..` steps climb above the root.
	 *
	 * `p` arrives percent-decoded exactly once by the request handler.
	 * Decoding it again here is not hygiene but corruption: a path whose
	 * single decode legitimately contains `+` or `%` (`/a+b.html`, or
	 * `/100%.html` from `/100%25.html`) would be form-decoded a second
	 * time and made to name a different file. Double-encoded traversal
	 * needs no second decode to stay caught: `%252e` decodes once to the
	 * literal text `%2e`, which no filesystem reads as a dot.
	 *
	 * A `..` inside a segment, as in `/compare/v1.2..v1.3`, is part of a
	 * name, and such a path is routed like any other.
	 */
	@:noCompletion public static inline function normalize(p:String):Null<String> {
		return HttpSyntax.normalizePath(p);
	}

	/**
	 * The filesystem path of the web path `web` under the root, or null when
	 * it would leave the root.
	 */
	@:noCompletion public static function abs(cfg:HTTPServerConfig, web:String):Null<String> {
		var root:String = __normalizedRoot(cfg.rootDirectory.nativePath);
		var rootSlash:String = root.endsWith("/") ? root : root + "/";
		var rel:String = web.startsWith("/") ? web.substr(1) : web;
		var a:String = Path.normalize(rootSlash + rel);

		if (!(a == root || a.startsWith(rootSlash))) {
			return null;
		}

		return a;
	}

	@:noCompletion public static inline function isFile(cfg:HTTPServerConfig, web:String):Bool {
		return __isFile(cfg, web, __probe(cfg, web));
	}

	@:noCompletion public static function dirIndex(cfg:HTTPServerConfig, dirWeb:String):Null<String> {
		var index:Null<IndexMatch> = __indexOf(cfg, dirWeb, __probe(cfg, dirWeb));
		return index == null ? null : index.web;
	}

	// The root as Path.normalize leaves it, kept with the root it was made
	// from, so it is not normalized again for every lookup. One object, so
	// a thread that reads it sees a pair that belongs together.
	@:noCompletion private static var __rootPair:Null<RootPair> = null;

	@:noCompletion private static function __normalizedRoot(native:String):String {
		var pair:Null<RootPair> = __rootPair;
		if (pair == null || pair.native != native) {
			pair = new RootPair(native, Path.normalize(native));
			__rootPair = pair;
		}
		return pair.normalized;
	}

	/** What is at the web path `web` under the root; `NONE` outside it. */
	@:noCompletion private static function __probe(cfg:HTTPServerConfig, web:String):FileFacts {
		if (!FileFacts.FAST) {
			return FileFacts.UNKNOWN;
		}
		var a:Null<String> = abs(cfg, web);
		return a == null ? FileFacts.NONE : FileFacts.of(a);
	}

	/** Whether `web`, whose facts are `facts`, is a file: asked of the system when they are not known. */
	@:noCompletion private static function __isFile(cfg:HTTPServerConfig, web:String, facts:FileFacts):Bool {
		if (facts.known) {
			return facts.exists && !facts.directory;
		}
		var a:Null<String> = abs(cfg, web);
		return a != null && sys.FileSystem.exists(a) && !sys.FileSystem.isDirectory(a);
	}

	/** The index of the directory `dirWeb`, whose facts are `dirFacts`, with its own facts, or null. */
	@:noCompletion private static function __indexOf(cfg:HTTPServerConfig, dirWeb:String, dirFacts:FileFacts):Null<IndexMatch> {
		if (dirFacts.known && !(dirFacts.exists && dirFacts.directory)) {
			return null;
		}
		var a:Null<String> = abs(cfg, dirWeb);
		if (a == null || (!dirFacts.known && (!sys.FileSystem.exists(a) || !sys.FileSystem.isDirectory(a)))) {
			return null;
		}

		for (i in cfg.directoryIndex) {
			// An index the server cannot serve is not an index. With PHP off
			// there is no bridge to execute index.php, so a directory holding
			// both index.php and index.html resolves to the one that can be
			// delivered, not to a 404.
			if (!cfg.phpEnabled && isPhpPath(i)) {
				continue;
			}

			var p:String = Path.join([a, i]);
			var facts:FileFacts = FileFacts.FAST ? FileFacts.of(p) : FileFacts.UNKNOWN;
			var found:Bool = facts.known ? facts.exists && !facts.directory : sys.FileSystem.exists(p) && !sys.FileSystem.isDirectory(p);
			if (found) {
				return new IndexMatch((dirWeb.endsWith("/") ? dirWeb : dirWeb + "/") + i, facts);
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
	 * segment captured into `$1` whose own value contained `$2` would have
	 * that `$2` substituted by the next iteration, letting the request rather
	 * than the rule author decide part of the rewritten target.
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
				case RewriteConditionType.DirExists:
				var facts:FileFacts = __probe(cfg, working);
				if (facts.known) {
					facts.exists && facts.directory;
				} else {
					final a = abs(cfg, working);
					a != null && sys.FileSystem.exists(a) && sys.FileSystem.isDirectory(a);
				}
				case RewriteConditionType.Method:
					var re:EReg = __compile(c.pattern, true);
					re.match(method);
				case RewriteConditionType.Header:
					// Lowercase, as both parsers store a request's fields, so a
					// key written "X-Test" matches what a client sends.
					var v:String = (headers != null && c.key != null) ? headers.get(c.key.toLowerCase()) : null;
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
	#if target.threaded
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
		var cache:PatternCache = #if target.threaded __patterns.value #else __patterns #end;

		if (cache == null) {
			cache = new PatternCache();
			#if target.threaded
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

/**
	Where a request resolved to. A class, so natively its fields are read
	directly rather than found by name, three to five times a request.
**/
final class Decision {
	public final finalPath:String;
	public final toPHP:Bool;
	public final isStatic:Bool;
	public final query:String;
	public final preserveURI:Bool;

	/**
		What the resolver found at `finalPath` when it found a file there it
		could describe in one call: the handler serves it from these rather
		than asking again. Null otherwise.
	**/
	public final facts:Null<FileFacts>;

	public function new(finalPath:String, toPHP:Bool, isStatic:Bool, query:String, preserveURI:Bool, facts:Null<FileFacts>) {
		this.finalPath = finalPath;
		this.toPHP = toPHP;
		this.isStatic = isStatic;
		this.query = query;
		this.preserveURI = preserveURI;
		this.facts = facts;
	}
}

/**
	What `RewriteEngine.decide` found at the request's own path, for a request
	it resolved to nothing: the handler answers that from these rather than
	asking again. One a handler, reused.
**/
final class FileSeen {
	public var path:Null<String> = null;
	public var facts:Null<FileFacts> = null;

	public function new() {}
}

private final class IndexMatch {
	public final web:String;
	public final facts:FileFacts;

	public function new(web:String, facts:FileFacts) {
		this.web = web;
		this.facts = facts;
	}
}

private final class RootPair {
	public final native:String;
	public final normalized:String;

	public function new(native:String, normalized:String) {
		this.native = native;
		this.normalized = normalized;
	}
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
#end
