package crossbyte.url;

import crossbyte.FieldStruct;

/**
	Abstract representing a set of URL query parameters with **multi-value support**.

	`URLVariables` encodes/decodes data using the `application/x-www-form-urlencoded`
	convention. Repeated keys are preserved (e.g. `a=1&a=2`) and are stored internally
	as `Array<String>` per key.

	### Key behaviors

	- **Decode**: Accepts both `&` and `;` as pair separators. Existing content is **cleared**.
	- **Encode**: Produces `k=v&k=v2` for repeated keys. Values and keys are percent-encoded.
	- **Access (dot/bracket)**: `vars.foo` or `vars["foo"]` returns/sets the **first value**
	  for `foo`. Use `all("foo")` to get the full `Array<String>`.
	- **Append**: Use `append(key, value)` to add an additional value while preserving
	  prior values for the same key.

	> Internally this is an abstract over `FieldStruct<Array<String>>` (a `StringMap`-based
	> structure). Iteration order of keys is implementation-dependent.

	@example Basic usage
	```haxe
	var v = new URLVariables("a=1&a=2&b=");
	trace(v.all("a"));     // [ "1", "2" ]
	trace(v["a"]);         // "1"
	v.append("a", "3");
	trace(v.toString());   // "a=1&a=2&a=3&b=" (order of keys may vary)
	```
**/
abstract URLVariables(FieldStruct<Array<String>>) from FieldStruct<Array<String>> to FieldStruct<Array<String>> {
	/**
		Create a new `URLVariables`. If `source` is provided, it is immediately
		{@link decode}d into this instance.

		@param source Optional URL-encoded query string (e.g. `"a=1&b=2"`).
	**/
	public inline function new(source:String = null) {
		this = new FieldStruct();

		if (source != null) {
			decode(source);
		}
	}

	/**
		Populate this instance from a URL-encoded string.

		- Accepts `&` **and** `;` as separators.
		- Missing values (e.g. `b` in `"b"`) decode as empty strings.
		- **Clears** existing keys before decoding.
		- Repeated keys append in order of appearance.

		@param source A URL-encoded query string.
	**/
	public function decode(source:String):Void {
		FieldStruct.clear(this);

		for (pair in source.split(";").join("&").split("&")) {
			if (pair == "") {
				continue;
			}
			var eq:Int = pair.indexOf("=");
			var k:String = StringTools.urlDecode(eq > 0 ? pair.substr(0, eq) : pair);
			var v:String = StringTools.urlDecode(eq > 0 ? pair.substr(eq + 1) : "");
			var a:Array<String> = this[k];
			if (a == null) {
				this[k] = [v];
			} else {
				a.push(v);
			}
		}
	}

	/**
		Serialize all parameters to a URL-encoded string using
		`application/x-www-form-urlencoded`.

		- Repeated keys emit multiple `k=v` pairs (e.g. `a=1&a=2`).
		- Empty values emit as `k=`.

		@return A URL-encoded query string. Key order is implementation-dependent.
	**/
	public function toString():String {
		var out:Array<String> = new Array<String>();
		for (kv in FieldStruct.iterator(this)) {
			var k:String = StringTools.urlEncode(kv.key);
			var a:Array<String> = kv.value;
			if (a == null || a.length == 0) {
				out.push(k + "=");
			} else {
				for (v in a) {
					out.push(k + "=" + StringTools.urlEncode(v));
				}
			}
		}
		return out.join("&");
	}

	/**
		Append a value to a key without overwriting existing values.

		@param key   Parameter name.
		@param value Value to append (unencoded; encoding happens in {@link toString}).
	**/
	public inline function append(key:String, value:String):Void {
		var a:Array<String> = this[key];
		if (a == null) {
			this[key] = [value];
		} else {
			a.push(value);
		}
	}

	/**
		Get **all** values for a key.

		@param key Parameter name.
		@return An array of values (empty if the key does not exist).
	**/
	public inline function all(key:String):Array<String> {
		var a:Array<String> = this[key];
		return (a == null) ? [] : a;
	}

	/**
		Array-style access (read): returns the **first** value for `key`, or `null`
		if the key is not present. `all` to retrieve all values.

		@example
		```haxe
		var v = new URLVariables("a=1&a=2");
		trace(v["a"]);      // "1"
		trace(v.all("a"));  // ["1","2"]
		```
	**/
	@:arrayAccess public inline function get(key:String):Null<String> {
		final a = this[key]; // FieldStruct's arrayAccess
		return (a == null || a.length == 0) ? null : a[0];
	}

	/**
		Array-style access (write): sets/replaces the **first** value for `key`.
		Other existing values for that key are kept as-is.

		@param key   Parameter name.
		@param value New first value.
		@return The value written.
	**/
	@:arrayAccess public inline function set(key:String, value:String):String {
		var a:Array<String> = this[key];
		if (a == null) {
			this[key] = [value];
		} else {
			if (a.length == 0) {
				a.push(value);
			} else {
				a[0] = value;
			}
		}
		return value;
	}

	@:noCompletion @:op(a.b) private inline function __read(name:String):Null<String> {
		return get(name);
	}

	@:noCompletion @:op(a.b) private inline function __write(name:String, v:String):String {
		return set(name, v);
	}
}
