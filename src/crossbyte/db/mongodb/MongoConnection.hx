package crossbyte.db.mongodb;

import crossbyte.errors.ArgumentError;
import crossbyte.errors.IOError;
import crossbyte.events.EventDispatcher;
import crossbyte.events.SQLError;
import crossbyte.events.SQLErrorEvent;
import crossbyte.events.SQLEvent;
#if php
import php.Global;
import php.Syntax;
#end

class MongoConnection extends EventDispatcher {
	public static final isSupported:Bool = #if php __checkSupport() #else false #end;

	public var connected(get, null):Bool;
	public var inTransaction(get, null):Bool;
	public var lastInsertRowID(get, null):Int;
	public var affectedRows(get, null):Int;
	public var serverVersion(get, null):String;

	@:noCompletion private var __manager:Dynamic;
	@:noCompletion private var __database:String;
	@:noCompletion private var __uri:String;
	@:noCompletion private var __lastInsertRowID:Int = 0;
	@:noCompletion private var __lastAffectedRows:Int = 0;

	public function new() {
		super();
	}

	public function open(cfg:MongoConfig):Void {
		__requireSupported();
		if (cfg == null) {
			throw "MongoConnection: config is required.";
		}

		try {
			__uri = (cfg.uri != null && cfg.uri != "") ? cfg.uri : __buildUri(cfg);
			__database = (cfg.database != null && cfg.database != "") ? cfg.database : null;
			__manager = Syntax.code("new \\MongoDB\\Driver\\Manager({0})", __uri);
			__dispatchEvent(new SQLEvent(SQLEvent.OPEN));
		} catch (e:Dynamic) {
			throw new IOError(e);
		}
	}

	public function close():Void {
		if (__manager != null) {
			__manager = null;
			__dispatchEvent(new SQLEvent(SQLEvent.CLOSE));
		}
	}

	public function ping():Bool {
		if (!connected) {
			return false;
		}
		try {
			var rs = request('{"ping":1}');
			return rs != null && rs.hasNext();
		} catch (_:Dynamic) {
			return false;
		}
	}

	public inline function request(jsonCommand:String):MongoResultSet {
		__requireConnected();
		__lastAffectedRows = 0;

		if (jsonCommand == null || jsonCommand == "") {
			throw "MongoConnection: command text is required.";
		}

		try {
			var commandRows:Dynamic = Syntax.code(
				'
					$raw = {0};
					$db = {1};
					$manager = {2};
					$parsed = json_decode($raw, true);

					if ($parsed === null || !is_array($parsed)) {
						throw new Exception("Mongo command must be a valid JSON object.");
					}
					$cmd = new MongoDB\\Driver\\Command($parsed);
					$cursor = $manager->executeCommand($db, $cmd);
					$out = [];
					foreach ($cursor as $row) {
						$out[] = (array)$row;
					}
					return $out;
				',
				jsonCommand,
				__database != null ? __database : "",
				__manager
			);

			var rows = __toRows(commandRows);
			__lastAffectedRows = rows.length;
			return new MongoResultSet(rows);
		} catch (e:Dynamic) {
			throw new IOError(e);
		}
	}

	public function get_connected():Bool {
		return __manager != null;
	}

	public function get_inTransaction():Bool {
		return false;
	}

	public function get_lastInsertRowID():Int {
		return __lastInsertRowID;
	}

	public function get_affectedRows():Int {
		return __lastAffectedRows;
	}

	public function get_serverVersion():String {
		try {
			var rs = request('{"buildInfo":1}');
			if (!rs.hasNext()) {
				return "";
			}

			var row = rs.next();
			if (row == null) {
				return "";
			}

			var direct = Reflect.field(row, "version");
			if (direct != null) {
				return Std.string(direct);
			}
			var keys:Array<String> = Reflect.fields(row);
			if (keys.length > 0) {
				return Std.string(Reflect.field(row, keys[0]));
			}
		} catch (_:Dynamic) {}
		return "";
	}

	@:noCompletion private function __buildUri(cfg:MongoConfig):String {
		var host:String = cfg.host != null && cfg.host != "" ? cfg.host : "127.0.0.1";
		var port:Int = cfg.port != null ? cfg.port : 27017;
		var credentials:String = "";

		if (cfg.username != null && cfg.password != null && cfg.username != "") {
			credentials = cfg.username;
			credentials += ":" + cfg.password;
			credentials += "@";
		}

		return "mongodb://" + credentials + host + ":" + port;
	}

	@:noCompletion private inline function __requireSupported():Void {
		if (!isSupported) {
			throw new ArgumentError("MongoConnection is not supported on this target or extension is not available.");
		}
	}

	@:noCompletion private inline function __requireConnected():Void {
		if (__manager == null) {
			throw "MongoConnection: no connection set.";
		}
	}

	@:noCompletion private function __toRows(raw:Dynamic):Array<Dynamic> {
		if (raw == null) {
			return [];
		}
		if (Std.isOfType(raw, Array)) {
			return cast raw;
		}
		return [raw];
	}

	@:noCompletion private inline function __dispatchError(op:String, msg:String, e:Dynamic):Void {
		__dispatchEvent(new SQLErrorEvent(SQLErrorEvent.ERROR, new SQLError(op, e, msg)));
	}

	@:noCompletion private static function __checkSupport():Bool {
		#if php
		return Global.extension_loaded("mongodb");
		#else
		return false;
		#end
	}
}

private class MongoResultSet {
	public var length(default, null):Int = 0;
	@:noCompletion private var __rows:Array<Dynamic>;
	@:noCompletion private var __index:Int = 0;

	public function new(rows:Array<Dynamic>) {
		__rows = rows != null ? rows : [];
		length = __rows.length;
	}

	public function hasNext():Bool {
		return __index < __rows.length;
	}

	public function next():Dynamic {
		var row = __rows[__index];
		__index++;
		return row;
	}
}
