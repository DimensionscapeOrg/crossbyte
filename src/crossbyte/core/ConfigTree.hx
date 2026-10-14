package crossbyte.core;

import crossbyte.auth.Secret;
import crossbyte.errors.ArgumentError;
import crossbyte.utils.IntParse;

/**
 * Nested configuration: JSON documents, defaults and environment variables
 * layered into one tree, read through typed getters.
 *
 * `Config` holds flat strings under case-folded keys, which suits `key=value`
 * files. A service whose settings are sections, lists of objects and
 * camelCase names (`realm.endpoints[0].host`, `auth.token.maxAge`) needs a
 * tree, and this is that tree:
 *
 * ```haxe
 * var config = new ConfigTree()
 *     .withJsonFile("config.json")
 *     .withJsonFile("config.local.json", true)
 *     .withDefaults({server: {port: 8080, host: "0.0.0.0"}, log: {level: "info"}})
 *     .withEnvironment("MYSERVICE_");
 *
 * var port:Int = config.getInt("server.port");
 * var firstHost:String = config.getString("realm.endpoints[0].host");
 * var key:String = config.secret("auth.token.key");
 * ```
 *
 * **Layers.** Each `with` call merges into what is there and returns `this`.
 * A JSON document or file, and the environment, override what came before;
 * `withDefaults` fills in only what is still missing, so it can come first
 * or last. Objects merge key by key, at every depth. An array, a string or a
 * number is a value: a later one replaces it whole, arrays included, so a
 * list in an override file is the list, not an addition to the defaults.
 *
 * **Paths** are keys joined by `.`, with array elements as `[0]` or `.0`:
 * `realm.endpoints[0].host` and `realm.endpoints.0.host` are the same. Keys
 * are matched exactly, case included, so a key that holds a `.` cannot be
 * reached by a path.
 *
 * **Typed reads are strict**, as `Config`'s are: `getInt` reads the JSON
 * number `80` and the string `"80"`, refuses `80.5` and `"80a80"` rather
 * than reading 80, and refuses a value too big for an `Int`. A value of the
 * wrong kind (an object where a number belongs) throws as well. A missing
 * value, or JSON `null`, gives the fallback. Each refusal is an
 * `ArgumentError` that names the path.
 *
 * `Dynamic` appears only where JSON-shaped values cross into or out of the
 * tree (`withDefaults`, `set`, `get`, `getArray`, `require`); the tree itself
 * is typed, and every typed getter reads it without reflection.
 */
class ConfigTree {
	/** The deepest a document may nest objects and arrays. **/
	public static inline var MAX_DEPTH:Int = 64;

	@:noCompletion private var __root:ConfigNode;

	/**
	 * An empty tree, or one over `values` (an object literal, as
	 * `withDefaults` takes).
	 */
	public function new(?values:Dynamic) {
		__root = Table(new ConfigTable());
		if (values != null) {
			__root = __merge(__root, __fromValue(values, "", 0), true);
		}
	}

	/**
	 * A tree read from a JSON document, whose top level must be an object.
	 *
	 * @param origin What to call the document in an error, such as its file
	 *        name. Defaults to `JSON`.
	 * @throws ArgumentError When the text is not JSON, naming `origin`, the
	 *         line and the column, or its top level is not an object.
	 */
	public static function fromJson(text:String, ?origin:String):ConfigTree {
		return new ConfigTree().withJson(text, origin);
	}

	/**
	 * Merges a JSON document over this tree: its values override the ones
	 * here. The top level must be an object.
	 *
	 * @throws ArgumentError As `fromJson`.
	 */
	public function withJson(text:String, ?origin:String):ConfigTree {
		var name:String = origin == null ? "JSON" : origin;
		if (text == null) {
			throw new ArgumentError('Config document $name is null.');
		}
		var parsed:ConfigNode = new ConfigJson(text, name).parse();
		switch (parsed) {
			case Table(_):
			default:
				throw new ArgumentError('Config document $name is not a JSON object at its top level.');
		}
		__root = __merge(__root, parsed, true);
		return this;
	}

	/**
	 * Merges the JSON file at `path` over this tree, as `withJson` does,
	 * naming the file in any error.
	 *
	 * @param optional When `true`, a missing file is skipped rather than
	 *        an error, for an override file that may not be there. A file that
	 *        is there but is not JSON throws either way: running on defaults
	 *        would drop every setting in it.
	 * @throws ArgumentError When the file is missing (and not optional),
	 *         cannot be read, or is not a JSON object.
	 */
	public function withJsonFile(path:String, optional:Bool = false):ConfigTree {
		#if (js && !nodejs)
		throw new crossbyte.errors.IllegalOperationError("ConfigTree.withJsonFile reads from disk, which a browser has no access to; read the text yourself and pass it to withJson.");
		#else
		if (path == null || path == "") {
			throw new ArgumentError("Config file path must not be empty.");
		}
		if (!sys.FileSystem.exists(path) || sys.FileSystem.isDirectory(path)) {
			if (optional) {
				return this;
			}
			throw new ArgumentError('Config file not found: $path');
		}
		var text:String;
		try {
			text = sys.io.File.getContent(path);
		} catch (e:Dynamic) {
			throw new ArgumentError('Config file $path could not be read: ' + Std.string(e));
		}
		return withJson(text, path);
		#end
	}

	/**
	 * Fills in values that are still missing, at every depth: an object
	 * literal (`{server: {port: 8080}}`), a `Map<String, Dynamic>`, or
	 * another tree. A value already here, from any source, stays.
	 *
	 * @throws ArgumentError When `defaults` holds something that is not
	 *         JSON-shaped: strings, numbers, booleans, null, arrays and
	 *         objects only.
	 */
	public function withDefaults(defaults:Dynamic):ConfigTree {
		if (defaults != null) {
			__root = __merge(__root, __fromValue(defaults, "", 0), false);
		}
		return this;
	}

	/**
	 * Merges another tree over this one, its values overriding these.
	 */
	public function withTree(other:ConfigTree):ConfigTree {
		if (other != null) {
			__root = __merge(__root, __copy(other.__root), true);
		}
		return this;
	}

	/**
	 * Applies environment variables whose names start with `prefix`
	 * (compared in any case), overriding what is there.
	 *
	 * The rest of the name is a path, its parts joined by `separator`:
	 * with prefix `MYSERVICE_`, `MYSERVICE_SERVER__PORT` sets `server.port`
	 * and `MYSERVICE_REALM__ENDPOINTS__0__HOST` sets
	 * `realm.endpoints[0].host`. A separator straight after the prefix is
	 * dropped, so `MYSERVICE` works as a prefix too.
	 *
	 * Each part is matched to a key already in the tree by its letters and
	 * digits alone, in any case, so `MAX_AGE`, `MAXAGE` and `max-age` all
	 * reach `maxAge`: put a key in the defaults or a file to reach it by its
	 * own spelling. A part that matches no key adds one, spelt in lower case,
	 * and one that matches two (`max_age` and `maxAge` side by side) is
	 * refused as ambiguous. In an array, a part is an index: an element that
	 * is there, or the next one, which is added.
	 *
	 * The value is a string, which the typed getters read as they read any
	 * string. Where the tree holds an object or an array, the value must be
	 * JSON of the same kind, and replaces it: `MYSERVICE_ADMINS=["ana","li"]`.
	 *
	 * Variables are applied in name order, an index read as a number, so
	 * elements 0 to 11 are added in turn.
	 *
	 * @param prefix What the variables start with. Required: reading every
	 *        variable a process has into a tree would make `PATH` a setting.
	 * @param separator What joins the parts of a path. Defaults to `__`,
	 *        since a single `_` is part of many names.
	 * @param variables The variables to read, by name; this process's
	 *        environment when not given.
	 * @throws ArgumentError When a variable leads through a value that is
	 *         not an object or array, skips an index, has an empty part, is
	 *         ambiguous, or does not give the JSON an object or array needs.
	 *         The message names the variable, not its value.
	 */
	public function withEnvironment(prefix:String, separator:String = "__", ?variables:Map<String, String>):ConfigTree {
		if (prefix == null || prefix == "") {
			throw new ArgumentError("ConfigTree.withEnvironment needs a prefix.");
		}
		if (separator == null || separator == "") {
			throw new ArgumentError("ConfigTree.withEnvironment needs a separator.");
		}

		var source:Map<String, String> = variables;
		if (source == null) {
			#if (js && !nodejs)
			throw new crossbyte.errors.IllegalOperationError("ConfigTree.withEnvironment reads process environment variables, which a browser does not have; pass them as variables instead.");
			#else
			source = Sys.environment();
			#end
		}

		var upperPrefix:String = prefix.toUpperCase();
		var found:Array<EnvironmentEntry> = [];
		for (name => value in source) {
			if (name == null || value == null || name.length <= prefix.length || name.substr(0, prefix.length).toUpperCase() != upperPrefix) {
				continue;
			}
			var rest:String = name.substr(prefix.length);
			if (StringTools.startsWith(rest, separator)) {
				rest = rest.substr(separator.length);
			}
			if (rest == "") {
				continue;
			}
			found.push(new EnvironmentEntry(name, rest.split(separator), value));
		}
		found.sort(EnvironmentEntry.compare);

		for (entry in found) {
			__applyVariable(entry);
		}
		return this;
	}

	/**
	 * Sets the value at `path`, adding the objects on the way to it, and
	 * overriding what is there. `value` is JSON-shaped, as for
	 * `withDefaults`. An index may name an element that is there or the next.
	 */
	public function set(path:String, value:Dynamic):ConfigTree {
		var parts:Array<String> = __parse(path);
		var node:ConfigNode = __fromValue(value, path, 0);
		if (parts.length == 0) {
			switch (node) {
				case Table(_):
					__root = node;
				default:
					throw new ArgumentError("The top of a config tree is an object.");
			}
			return this;
		}
		var parent:ConfigNode = __root;
		for (i in 0...parts.length - 1) {
			parent = __child(parent, parts, i, parts[i + 1], path);
		}
		__put(parent, parts[parts.length - 1], node, path);
		return this;
	}

	/**
	 * Whether a value other than JSON `null` is at `path`.
	 */
	public function has(path:String):Bool {
		return switch (__find(path)) {
			case null, Null: false;
			default: true;
		}
	}

	/**
	 * The value at `path` as plain Haxe values: a `String`, a `Float` (an
	 * `Int` where the JSON number is a whole one that fits), a `Bool`, an
	 * `Array<Dynamic>` or an anonymous object, a copy whatever is done to
	 * it. Null when missing. For code that hands a section to something that
	 * takes JSON-shaped data; prefer the typed getters.
	 */
	public function get(path:String):Null<Dynamic> {
		var node:Null<ConfigNode> = __find(path);
		return node == null ? null : __toValue(node);
	}

	/**
	 * The string at `path`, or `fallback` when it is missing. A number or a
	 * boolean reads as its JSON text (`80`, `true`).
	 *
	 * @throws ArgumentError When the value is an object or an array.
	 */
	public function getString(path:String, ?fallback:String):Null<String> {
		return switch (__find(path)) {
			case null, Null: fallback;
			case Text(text): text;
			case Number(_, text): text;
			case Flag(value): value ? "true" : "false";
			case Table(_), List(_): throw __wrongKind(path, "a string");
		}
	}

	/**
	 * The integer at `path`, or `fallback` when it is missing: a JSON number
	 * that is whole and fits an `Int`, or a string of one in decimal or
	 * `0x` hexadecimal, as `Config.getInt` reads it.
	 *
	 * @throws ArgumentError When the value is not such a number.
	 */
	public function getInt(path:String, ?fallback:Int):Null<Int> {
		return switch (__find(path)) {
			case null, Null: fallback;
			case Number(value, text):
				if (value != Math.ffloor(value) || value < -2147483648.0 || value > 2147483647.0) {
					throw new ArgumentError('Config value for "$path" is not an integer an Int can hold: $text');
				}
				Std.int(value);
			case Text(text): __parseInt(path, text);
			case Flag(_), Table(_), List(_): throw __wrongKind(path, "an integer");
		}
	}

	/**
	 * The number at `path`, or `fallback` when it is missing: a JSON number,
	 * or a string of one, as `Config.getFloat` reads it.
	 *
	 * @throws ArgumentError When the value is not a number.
	 */
	public function getFloat(path:String, ?fallback:Float):Null<Float> {
		return switch (__find(path)) {
			case null, Null: fallback;
			case Number(value, _): value;
			case Text(text):
				var raw:String = StringTools.trim(text);
				if (!~/^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.match(raw)) {
					throw new ArgumentError('Config value for "$path" is not a number: "$raw"');
				}
				Std.parseFloat(raw);
			case Flag(_), Table(_), List(_): throw __wrongKind(path, "a number");
		}
	}

	/**
	 * The boolean at `path`, or `fallback` when it is missing: JSON `true`
	 * or `false`, the numbers `1` and `0`, or a string that `Config.getBool`
	 * reads (`true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0`, in any case).
	 *
	 * @throws ArgumentError When the value is none of those.
	 */
	public function getBool(path:String, ?fallback:Bool):Null<Bool> {
		return switch (__find(path)) {
			case null, Null: fallback;
			case Flag(value): value;
			case Number(value, text):
				if (value == 1) true else if (value == 0) false else throw new ArgumentError('Config value for "$path" is not a boolean: $text');
			case Text(text):
				switch (StringTools.trim(text).toLowerCase()) {
					case "true", "yes", "on", "1": true;
					case "false", "no", "off", "0": false;
					default: throw new ArgumentError('Config value for "$path" is not a boolean: "${StringTools.trim(text)}"');
				}
			case Table(_), List(_): throw __wrongKind(path, "a boolean");
		}
	}

	/**
	 * The array at `path` as plain values, as `get` gives them, or null when
	 * it is missing. For an array of objects, `sections` reads each one
	 * through typed getters instead.
	 *
	 * @throws ArgumentError When the value is not an array.
	 */
	public function getArray(path:String):Null<Array<Dynamic>> {
		return switch (__find(path)) {
			case null, Null: null;
			case List(items): [for (item in items) __toValue(item)];
			default: throw __wrongKind(path, "an array");
		}
	}

	/**
	 * The array of strings at `path`, or `fallback` when it is missing. Each
	 * element is read as `getString` reads a value.
	 *
	 * @throws ArgumentError When the value is not an array, or an element is
	 *         an object or an array.
	 */
	public function getStrings(path:String, ?fallback:Array<String>):Null<Array<String>> {
		return switch (__find(path)) {
			case null, Null: fallback;
			case List(items):
				var out:Array<String> = [];
				for (i in 0...items.length) {
					out.push(switch (items[i]) {
						case Text(text): text;
						case Number(_, text): text;
						case Flag(value): value ? "true" : "false";
						case Null: null;
						case Table(_), List(_): throw __wrongKind('$path[$i]', "a string");
					});
				}
				out;
			default: throw __wrongKind(path, "an array");
		}
	}

	/**
	 * The object or array at `path` as a tree of its own, whose paths start
	 * from there: `config.section("realm").getInt("port")` reads
	 * `realm.port`. It is a view, not a copy: a change made through it is a
	 * change here. An empty tree when nothing is at `path`, so its getters give
	 * their fallbacks.
	 *
	 * @throws ArgumentError When the value is a string, a number or a
	 *         boolean.
	 */
	public function section(path:String):ConfigTree {
		return switch (__find(path)) {
			case null, Null: new ConfigTree();
			case node = Table(_), node = List(_): __view(node);
			default: throw __wrongKind(path, "an object");
		}
	}

	/**
	 * Each element of the array at `path` as a section, for an array of
	 * objects: `for (endpoint in config.sections("realm.endpoints"))
	 * endpoint.getString("host")`. Empty when nothing is at `path`.
	 *
	 * @throws ArgumentError When the value is not an array, or an element is
	 *         not an object or an array.
	 */
	public function sections(path:String):Array<ConfigTree> {
		return switch (__find(path)) {
			case null, Null: [];
			case List(items):
				var out:Array<ConfigTree> = [];
				for (i in 0...items.length) {
					switch (items[i]) {
						case Table(_), List(_): out.push(__view(items[i]));
						default: throw __wrongKind('$path[$i]', "an object");
					}
				}
				out;
			default: throw __wrongKind(path, "an array");
		}
	}

	/**
	 * The keys of the object at `path` (the top when not given), in the
	 * order they were first set; for an array, its indexes. Empty when
	 * nothing is there.
	 */
	public function keys(?path:String):Array<String> {
		return switch (__find(path == null ? "" : path)) {
			case Table(table): table.keys.copy();
			case List(items): [for (i in 0...items.length) Std.string(i)];
			default: [];
		}
	}

	/**
	 * The value at `path`, as `get` gives it, for one a service cannot start
	 * without.
	 *
	 * @throws ArgumentError When it is missing, JSON `null`, or a string that
	 *         is empty or only whitespace.
	 */
	public function require(path:String):Dynamic {
		var node:Null<ConfigNode> = __find(path);
		switch (node) {
			case null, Null:
				throw new ArgumentError('Required configuration value "$path" is missing.');
			case Text(text) if (StringTools.trim(text) == ""):
				throw new ArgumentError('Required configuration value "$path" is missing.');
			default:
		}
		return __toValue(node);
	}

	/**
	 * The secret the string at `path` names, through `Secret.resolve`:
	 * `env:NAME`, `file:PATH`, or the value itself. Required: a missing one
	 * throws, so a service never starts on an empty key.
	 *
	 * @throws ArgumentError When the value is missing or not a string, or
	 *         `Secret.resolve` refuses it.
	 */
	public function secret(path:String):String {
		return switch (__find(path)) {
			case null, Null: throw new ArgumentError('Required configuration value "$path" is missing.');
			case Text(text): Secret.resolve(text);
			default: throw __wrongKind(path, "a string");
		}
	}

	// ----- paths -----

	// A path's parts: keys and indexes, in order. "" is the top.
	@:noCompletion private static function __parse(path:String):Array<String> {
		if (path == null) {
			throw new ArgumentError("A config path must not be null.");
		}
		var parts:Array<String> = [];
		if (path == "") {
			return parts;
		}
		for (dotted in path.split(".")) {
			var open:Int = dotted.indexOf("[");
			var key:String = open < 0 ? dotted : dotted.substr(0, open);
			if (key != "") {
				parts.push(key);
			} else if (open != 0) {
				throw new ArgumentError('Config path "$path" has an empty part.');
			}
			while (open >= 0) {
				var close:Int = dotted.indexOf("]", open);
				if (close < 0) {
					throw new ArgumentError('Config path "$path" has a "[" with no "]".');
				}
				var index:String = dotted.substring(open + 1, close);
				if (IntParse.decimal(index) < 0) {
					throw new ArgumentError('Config path "$path" has an index that is not a number: [$index]');
				}
				parts.push(index);
				open = close + 1 < dotted.length ? (dotted.charAt(close + 1) == "[" ? close + 1 : -2) : -1;
				if (open == -2) {
					throw new ArgumentError('Config path "$path" has text after an index; separate a key with ".".');
				}
			}
		}
		return parts;
	}

	@:noCompletion private function __find(path:String):Null<ConfigNode> {
		var node:ConfigNode = __root;
		for (part in __parse(path)) {
			switch (node) {
				case Table(table):
					node = table.values.get(part);
					if (node == null) {
						return null;
					}
				case List(items):
					var index:Int = IntParse.decimal(part);
					if (index < 0 || index >= items.length) {
						return null;
					}
					node = items[index];
				default:
					return null;
			}
		}
		return node;
	}

	// The object or array under `parent` at `parts[at]`, made (as an array
	// when the part after it is an index) where nothing is there.
	@:noCompletion private function __child(parent:ConfigNode, parts:Array<String>, at:Int, next:String, path:String):ConfigNode {
		var part:String = parts[at];
		var existing:Null<ConfigNode> = switch (parent) {
			case Table(table): table.values.get(part);
			case List(items):
				var index:Int = IntParse.decimal(part);
				index >= 0 && index < items.length ? items[index] : null;
			default: null;
		}
		switch (existing) {
			case Table(_), List(_):
				return existing;
			case null, Null:
				var made:ConfigNode = IntParse.decimal(next) >= 0 ? List([]) : Table(new ConfigTable());
				__put(parent, part, made, path);
				return made;
			default:
				throw new ArgumentError('Config path "$path" leads through "${parts.slice(0, at + 1).join(".")}", which is a value, not an object or array.');
		}
	}

	@:noCompletion private static function __put(parent:ConfigNode, part:String, node:ConfigNode, path:String):Void {
		switch (parent) {
			case Table(table):
				table.set(part, node);
			case List(items):
				var index:Int = IntParse.decimal(part);
				if (index < 0 || index > items.length) {
					throw new ArgumentError('Config path "$path" names element $part of an array of ${items.length}; only an element that is there or the next can be set.');
				}
				if (index == items.length) {
					items.push(node);
				} else {
					items[index] = node;
				}
			default:
				throw new ArgumentError('Config path "$path" leads through a value, not an object or array.');
		}
	}

	// ----- the environment -----

	@:noCompletion private function __applyVariable(entry:EnvironmentEntry):Void {
		var parts:Array<String> = entry.parts;
		var name:String = entry.name;
		for (part in parts) {
			if (part == "") {
				throw new ArgumentError('Environment variable $name has an empty part between its separators.');
			}
		}

		var node:ConfigNode = __root;
		for (i in 0...parts.length) {
			var last:Bool = i == parts.length - 1;
			switch (node) {
				case Table(table):
					var key:String = __matchKey(table, parts[i], name);
					if (last) {
						table.set(key, __environmentValue(table.values.get(key), entry));
						return;
					}
					var next:Null<ConfigNode> = table.values.get(key);
					switch (next) {
						case Table(_), List(_):
						case null, Null:
							next = IntParse.decimal(parts[i + 1]) >= 0 ? List([]) : Table(new ConfigTable());
							table.set(key, next);
						default:
							throw new ArgumentError('Environment variable $name leads through "$key", which is a value, not an object or array.');
					}
					node = next;
				case List(items):
					var index:Int = IntParse.decimal(parts[i]);
					if (index < 0) {
						throw new ArgumentError('Environment variable $name gives "${parts[i]}" where an array index belongs.');
					}
					if (index > items.length) {
						throw new ArgumentError('Environment variable $name names element $index of an array of ${items.length}; only an element that is there or the next can be set.');
					}
					var current:Null<ConfigNode> = index < items.length ? items[index] : null;
					if (last) {
						var value:ConfigNode = __environmentValue(current, entry);
						if (index == items.length) {
							items.push(value);
						} else {
							items[index] = value;
						}
						return;
					}
					switch (current) {
						case Table(_), List(_):
						case null, Null:
							current = IntParse.decimal(parts[i + 1]) >= 0 ? List([]) : Table(new ConfigTable());
							if (index == items.length) {
								items.push(current);
							} else {
								items[index] = current;
							}
						default:
							throw new ArgumentError('Environment variable $name leads through element $index, which is a value, not an object or array.');
					}
					node = current;
				default:
					throw new ArgumentError('Environment variable $name leads through a value, not an object or array.');
			}
		}
	}

	// The key in `table` a variable's part reaches: its own spelling, else
	// the one key whose letters and digits match it in any case, else the
	// part in lower case.
	@:noCompletion private static function __matchKey(table:ConfigTable, part:String, name:String):String {
		if (table.values.exists(part)) {
			return part;
		}
		var wanted:String = __fold(part);
		var match:Null<String> = null;
		for (key in table.keys) {
			if (__fold(key) == wanted) {
				if (match != null) {
					throw new ArgumentError('Environment variable $name could set "$match" or "$key"; rename one of them.');
				}
				match = key;
			}
		}
		return match != null ? match : part.toLowerCase();
	}

	@:noCompletion private static function __fold(key:String):String {
		var out:StringBuf = new StringBuf();
		for (i in 0...key.length) {
			var code:Int = StringTools.fastCodeAt(key, i);
			if (code >= "A".code && code <= "Z".code) {
				out.addChar(code + 32);
			} else if ((code >= "a".code && code <= "z".code) || (code >= "0".code && code <= "9".code) || code >= 0x80) {
				out.addChar(code);
			}
		}
		return out.toString();
	}

	@:noCompletion private static function __environmentValue(current:Null<ConfigNode>, entry:EnvironmentEntry):ConfigNode {
		switch (current) {
			case Table(_), List(_):
				var parsed:ConfigNode;
				try {
					parsed = new ConfigJson(entry.value, "environment variable " + entry.name).parse();
				} catch (_:Dynamic) {
					throw new ArgumentError('Environment variable ${entry.name} sets an object or array, so its value must be JSON of one.');
				}
				var same:Bool = switch [current, parsed] {
					case [Table(_), Table(_)], [List(_), List(_)]: true;
					default: false;
				}
				if (!same) {
					throw new ArgumentError('Environment variable ${entry.name} sets an object or array, so its value must be JSON of one.');
				}
				return parsed;
			default:
				return Text(entry.value);
		}
	}

	// ----- merging and conversion -----

	// `over` merged into `base`: objects key by key; elsewhere `over` wins
	// when `overWins`, and otherwise only where `base` has nothing.
	@:noCompletion private static function __merge(base:ConfigNode, over:ConfigNode, overWins:Bool):ConfigNode {
		switch [base, over] {
			case [Table(into), Table(from)]:
				for (key in from.keys) {
					var mine:Null<ConfigNode> = into.values.get(key);
					into.set(key, mine == null ? from.values.get(key) : __merge(mine, from.values.get(key), overWins));
				}
				return base;
			case [Null, _]:
				return over;
			case [_, Null]:
				return overWins ? over : base;
			default:
				return overWins ? over : base;
		}
	}

	@:noCompletion private static function __copy(node:ConfigNode):ConfigNode {
		return switch (node) {
			case Table(table):
				var copy:ConfigTable = new ConfigTable();
				for (key in table.keys) {
					copy.set(key, __copy(table.values.get(key)));
				}
				Table(copy);
			case List(items): List([for (item in items) __copy(item)]);
			default: node;
		}
	}

	@:noCompletion private static function __view(node:ConfigNode):ConfigTree {
		var tree:ConfigTree = new ConfigTree();
		tree.__root = node;
		return tree;
	}

	// A JSON-shaped Haxe value as a node: the one place values come in by
	// reflection.
	@:noCompletion private static function __fromValue(value:Dynamic, path:String, depth:Int):ConfigNode {
		if (depth > MAX_DEPTH) {
			throw new ArgumentError('Config value at "$path" nests more than $MAX_DEPTH levels deep.');
		}
		if (value == null) {
			return Null;
		}
		if (Std.isOfType(value, String)) {
			return Text(value);
		}
		if (Std.isOfType(value, Bool)) {
			return Flag(value);
		}
		if (Std.isOfType(value, Int)) {
			var whole:Int = value;
			return Number(whole, Std.string(whole));
		}
		if (Std.isOfType(value, Float)) {
			var number:Float = value;
			if (Math.isNaN(number) || !Math.isFinite(number)) {
				throw new ArgumentError('Config value at "$path" is not a finite number.');
			}
			return Number(number, __numberText(number));
		}
		if (Std.isOfType(value, ConfigTree)) {
			return __copy((value : ConfigTree).__root);
		}
		if (Std.isOfType(value, Array)) {
			var array:Array<Dynamic> = value;
			return List([for (i in 0...array.length) __fromValue(array[i], '$path[$i]', depth + 1)]);
		}
		if (Std.isOfType(value, haxe.ds.StringMap)) {
			var map:haxe.ds.StringMap<Dynamic> = value;
			var table:ConfigTable = new ConfigTable();
			for (key => item in map) {
				table.set(key, __fromValue(item, path == "" ? key : '$path.$key', depth + 1));
			}
			return Table(table);
		}
		switch (Type.typeof(value)) {
			case TObject:
				var table:ConfigTable = new ConfigTable();
				for (key in Reflect.fields(value)) {
					table.set(key, __fromValue(Reflect.field(value, key), path == "" ? key : '$path.$key', depth + 1));
				}
				return Table(table);
			default:
				throw new ArgumentError('Config value at "$path" is not JSON-shaped: ' + Std.string(value));
		}
	}

	// A node as plain Haxe values: the one place values go out as Dynamic.
	@:noCompletion private static function __toValue(node:ConfigNode):Dynamic {
		return switch (node) {
			case Null: null;
			case Text(text): text;
			case Flag(value): value;
			case Number(value, _):
				if (value == Math.ffloor(value) && value >= -2147483648.0 && value <= 2147483647.0) {
					var whole:Int = Std.int(value);
					(whole : Dynamic);
				} else {
					(value : Dynamic);
				}
			case List(items): [for (item in items) __toValue(item)];
			case Table(table):
				var object:Dynamic = {};
				for (key in table.keys) {
					Reflect.setField(object, key, __toValue(table.values.get(key)));
				}
				object;
		}
	}

	@:noCompletion private static function __numberText(value:Float):String {
		if (value == Math.ffloor(value) && Math.abs(value) < 1e15) {
			// Whole: written without a fraction, as JSON would carry it.
			var negative:Bool = value < 0;
			var magnitude:Float = Math.abs(value);
			var digits:String = "";
			do {
				var digit:Int = Std.int(magnitude - Math.ffloor(magnitude / 10) * 10);
				digits = digit + digits;
				magnitude = Math.ffloor(magnitude / 10);
			} while (magnitude > 0);
			return negative ? "-" + digits : digits;
		}
		return Std.string(value);
	}

	@:noCompletion private static function __parseInt(path:String, text:String):Int {
		var raw:String = StringTools.trim(text);
		if (!~/^[+-]?(?:[0-9]+|0[xX][0-9a-fA-F]+)$/.match(raw)) {
			throw new ArgumentError('Config value for "$path" is not an integer: "$raw"');
		}
		var negative:Bool = StringTools.startsWith(raw, "-");
		var digits:String = (negative || StringTools.startsWith(raw, "+")) ? raw.substr(1) : raw;
		var hex:Bool = StringTools.startsWith(digits, "0x") || StringTools.startsWith(digits, "0X");
		// Up to 2147483648 for a negative number, which is -2147483648.
		var parsed:Int = hex ? IntParse.hex(digits.substr(2)) : IntParse.decimal(digits);
		if (parsed < 0) {
			if (negative && !hex && StringTools.replace(StringTools.trim(digits), "0", "") != "" && __isMinimum(digits)) {
				return -2147483647 - 1;
			}
			throw new ArgumentError('Config value for "$path" is not an integer an Int can hold: "$raw"');
		}
		return negative ? -parsed : parsed;
	}

	// Whether `digits` (decimal, leading zeros allowed) is 2147483648.
	@:noCompletion private static function __isMinimum(digits:String):Bool {
		var start:Int = 0;
		while (start < digits.length - 1 && digits.charAt(start) == "0") {
			start++;
		}
		return digits.substr(start) == "2147483648";
	}

	@:noCompletion private static function __wrongKind(path:String, wanted:String):ArgumentError {
		return new ArgumentError('Config value for "$path" is not $wanted.');
	}
}

/** A value in a tree. **/
private enum ConfigNode {
	Null;
	Flag(value:Bool);
	// The number, and its text as written, so a getString of it gives back
	// what the document said.
	Number(value:Float, text:String);
	Text(text:String);
	List(items:Array<ConfigNode>);
	Table(table:ConfigTable);
}

/** An object's members, in the order first set. **/
private class ConfigTable {
	public final keys:Array<String> = [];
	public final values:Map<String, ConfigNode> = new Map();

	public function new() {}

	public function set(key:String, node:ConfigNode):Void {
		if (!values.exists(key)) {
			keys.push(key);
		}
		values.set(key, node);
	}
}

/** An environment variable that names a path. **/
private class EnvironmentEntry {
	public final name:String;
	public final parts:Array<String>;
	public final value:String;

	public function new(name:String, parts:Array<String>, value:String) {
		this.name = name;
		this.parts = parts;
		this.value = value;
	}

	// Part by part; two indexes as numbers, so 2 comes before 10.
	public static function compare(a:EnvironmentEntry, b:EnvironmentEntry):Int {
		var count:Int = a.parts.length < b.parts.length ? a.parts.length : b.parts.length;
		for (i in 0...count) {
			var left:String = a.parts[i].toUpperCase();
			var right:String = b.parts[i].toUpperCase();
			if (left == right) {
				continue;
			}
			var leftIndex:Int = IntParse.decimal(left);
			var rightIndex:Int = IntParse.decimal(right);
			if (leftIndex >= 0 && rightIndex >= 0) {
				return leftIndex < rightIndex ? -1 : 1;
			}
			return left < right ? -1 : 1;
		}
		return a.parts.length < b.parts.length ? -1 : (a.parts.length > b.parts.length ? 1 : 0);
	}
}


/**
	A strict JSON reader (RFC 8259: no comments, no trailing commas) that
	makes nodes directly, keeps an object's keys in order, keeps a number's
	text, and says where it stopped as a line and column. A byte order mark
	at the start is skipped.

	It reads the document's UTF-8 bytes, not its characters: on PHP a
	character read by index is found by walking the string from its start,
	which made a character-by-character reader take time in the square of the
	document's length there. The same on every target, PHP included, where
	`haxe.Json` is the native parser and words its errors its own way.
**/
private class ConfigJson {
	final bytes:haxe.io.Bytes;
	final origin:String;
	var at:Int = 0;
	var begin:Int = 0;
	var depth:Int = 0;

	public function new(text:String, origin:String) {
		this.bytes = haxe.io.Bytes.ofString(text);
		this.origin = origin;
	}

	public function parse():ConfigNode {
		if (bytes.length >= 3 && bytes.get(0) == 0xEF && bytes.get(1) == 0xBB && bytes.get(2) == 0xBF) {
			at = 3;
			begin = 3;
		}
		skipSpace();
		if (at >= bytes.length) {
			fail("the document is empty");
		}
		var value:ConfigNode = readValue();
		skipSpace();
		if (at < bytes.length) {
			fail("expected the end of the document");
		}
		return value;
	}

	function readValue():ConfigNode {
		var code:Int = peek();
		return switch (code) {
			case "{".code: readObject();
			case "[".code: readArray();
			case '"'.code: Text(readString());
			case "t".code: readWord("true", Flag(true));
			case "f".code: readWord("false", Flag(false));
			case "n".code: readWord("null", Null);
			default:
				if (code == "-".code || isDigit(code)) {
					readNumber();
				} else {
					fail("expected a value");
				}
		}
	}

	function readObject():ConfigNode {
		enter();
		at++;
		var table:ConfigTable = new ConfigTable();
		skipSpace();
		if (peek() == "}".code) {
			at++;
			depth--;
			return Table(table);
		}
		while (true) {
			skipSpace();
			if (peek() != '"'.code) {
				fail("expected a key in quotes");
			}
			var key:String = readString();
			skipSpace();
			if (peek() != ":".code) {
				fail('expected ":" after a key');
			}
			at++;
			skipSpace();
			table.set(key, readValue());
			skipSpace();
			var next:Int = peek();
			if (next == ",".code) {
				at++;
				continue;
			}
			if (next == "}".code) {
				at++;
				depth--;
				return Table(table);
			}
			fail('expected "," or "}"');
		}
	}

	function readArray():ConfigNode {
		enter();
		at++;
		var items:Array<ConfigNode> = [];
		skipSpace();
		if (peek() == "]".code) {
			at++;
			depth--;
			return List(items);
		}
		while (true) {
			skipSpace();
			items.push(readValue());
			skipSpace();
			var next:Int = peek();
			if (next == ",".code) {
				at++;
				continue;
			}
			if (next == "]".code) {
				at++;
				depth--;
				return List(items);
			}
			fail('expected "," or "]"');
		}
	}

	function readString():String {
		at++;
		var out:Null<StringBuf> = null;
		var start:Int = at;
		while (true) {
			if (at >= bytes.length) {
				fail("a string is not closed");
			}
			var code:Int = bytes.get(at);
			if (code == '"'.code) {
				var run:String = bytes.getString(start, at - start);
				at++;
				if (out == null) {
					return run;
				}
				out.add(run);
				return out.toString();
			}
			if (code < 0x20) {
				fail("a control character inside a string must be escaped");
			}
			if (code != "\\".code) {
				at++;
				continue;
			}
			if (out == null) {
				out = new StringBuf();
			}
			out.add(bytes.getString(start, at - start));
			at++;
			if (at >= bytes.length) {
				fail("a string is not closed");
			}
			var escaped:Int = bytes.get(at);
			at++;
			switch (escaped) {
				case '"'.code: out.addChar('"'.code);
				case "\\".code: out.addChar("\\".code);
				case "/".code: out.addChar("/".code);
				case "b".code: out.addChar(8);
				case "f".code: out.addChar(12);
				case "n".code: out.addChar(10);
				case "r".code: out.addChar(13);
				case "t".code: out.addChar(9);
				case "u".code:
					var unit:Int = readHex4();
					if (unit >= 0xD800 && unit <= 0xDBFF && at + 1 < bytes.length && bytes.get(at) == "\\".code && bytes.get(at + 1) == "u".code) {
						var save:Int = at;
						at += 2;
						var low:Int = readHex4();
						if (low >= 0xDC00 && low <= 0xDFFF) {
							unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
						} else {
							at = save;
						}
					}
					out.addChar(unit);
				default:
					at--;
					fail("unknown escape in a string");
			}
			start = at;
		}
	}

	function readHex4():Int {
		var value:Int = 0;
		for (i in 0...4) {
			var code:Int = peek();
			var digit:Int = if (isDigit(code)) {
				code - "0".code;
			} else if (code >= "a".code && code <= "f".code) {
				code - "a".code + 10;
			} else if (code >= "A".code && code <= "F".code) {
				code - "A".code + 10;
			} else {
				fail("a \\u escape needs four hex digits");
			}
			value = (value << 4) | digit;
			at++;
		}
		return value;
	}

	function readNumber():ConfigNode {
		var start:Int = at;
		if (peek() == "-".code) {
			at++;
		}
		if (peek() == "0".code) {
			at++;
		} else if (isDigit(peek())) {
			while (isDigit(peek())) {
				at++;
			}
		} else {
			fail("expected a digit");
		}
		if (peek() == ".".code) {
			at++;
			if (!isDigit(peek())) {
				fail("expected a digit after the decimal point");
			}
			while (isDigit(peek())) {
				at++;
			}
		}
		if (peek() == "e".code || peek() == "E".code) {
			at++;
			if (peek() == "+".code || peek() == "-".code) {
				at++;
			}
			if (!isDigit(peek())) {
				fail("expected a digit in the exponent");
			}
			while (isDigit(peek())) {
				at++;
			}
		}
		var written:String = bytes.getString(start, at - start);
		var value:Float = Std.parseFloat(written);
		if (!Math.isFinite(value)) {
			at = start;
			fail("a number is too large");
		}
		return Number(value, written);
	}

	function readWord(word:String, node:ConfigNode):ConfigNode {
		var start:Int = at;
		for (i in 0...word.length) {
			if (peek() != StringTools.fastCodeAt(word, i)) {
				at = start;
				fail("expected a value");
			}
			at++;
		}
		return node;
	}

	inline function isDigit(code:Int):Bool {
		return code >= "0".code && code <= "9".code;
	}

	inline function peek():Int {
		return at < bytes.length ? bytes.get(at) : -1;
	}

	function enter():Void {
		depth++;
		if (depth > ConfigTree.MAX_DEPTH) {
			fail('it nests more than ${ConfigTree.MAX_DEPTH} levels deep');
		}
	}

	function skipSpace():Void {
		while (at < bytes.length) {
			var code:Int = bytes.get(at);
			if (code != " ".code && code != "\t".code && code != "\n".code && code != "\r".code) {
				return;
			}
			at++;
		}
	}

	// Where `at` is, as a line and a column counted in characters: a byte
	// that continues a UTF-8 character is not a column of its own.
	function fail(what:String):Dynamic {
		var line:Int = 1;
		var column:Int = 1;
		var end:Int = at < bytes.length ? at : bytes.length;
		for (i in begin...end) {
			var code:Int = bytes.get(i);
			if (code == "\n".code) {
				line++;
				column = 1;
			} else if ((code & 0xC0) != 0x80) {
				column++;
			}
		}
		throw new ArgumentError('Bad JSON in $origin at line $line, column $column: $what.');
	}
}
