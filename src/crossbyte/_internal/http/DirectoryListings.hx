package crossbyte._internal.http;

// Server-side, like the resolver it serves: a page has no filesystem.
#if !(js && !nodejs)
import haxe.ds.StringMap;
#if target.threaded
import sys.thread.Tls;
#end

/**
 * What directories hold, remembered for a moment, for the static resolver's
 * spelling check.
 *
 * On Windows and macOS the resolver serves a file only under the spelling its
 * directory lists (see `HTTPRequestHandler.__isSpelledAsOnDisk`), and a
 * listing per path segment per request cost about a fifth of a static request
 * on Windows, growing with the directory. So a listing is kept, and a name it
 * contains is trusted for `FRESH_SECONDS`.
 *
 * Only a name that is found is trusted. A name not in a kept listing makes the
 * directory be listed again before the answer is no, so a file created a
 * moment ago is never refused for having been missed. What a kept listing can
 * get wrong is the other way: for up to a second after a rename that only
 * changes case, the old spelling is still accepted -- and the filesystem, which
 * answers to both, then serves the file under it.
 *
 * Held per thread, as `RewriteEngine` holds compiled patterns, so runtimes on
 * different threads never share a map.
 */
class DirectoryListings {
	/** Seconds a listing's names are trusted. **/
	public static inline var FRESH_SECONDS:Float = 1.0;

	/** Directories remembered at once; the cache starts over past this. **/
	public static inline var LIMIT:Int = 256;

	#if target.threaded
	private static final __perThread:Tls<DirectoryListings> = new Tls();
	#else
	private static var __shared:DirectoryListings;
	#end

	private var __listings:StringMap<Listing> = new StringMap();
	private var __size:Int = 0;

	private function new() {}

	/** This thread's listings. **/
	public static function current():DirectoryListings {
		#if target.threaded
		var listings:DirectoryListings = __perThread.value;
		if (listings == null) {
			listings = new DirectoryListings();
			__perThread.value = listings;
		}
		return listings;
		#else
		if (__shared == null) {
			__shared = new DirectoryListings();
		}
		return __shared;
		#end
	}

	/** Whether `directory` holds an entry spelled exactly `name`. **/
	public function lists(directory:String, name:String):Bool {
		var now:Float = haxe.Timer.stamp();
		var kept:Null<Listing> = __listings.get(directory);
		if (kept != null && now - kept.at < FRESH_SECONDS && kept.names.exists(name)) {
			return true;
		}

		var fresh:Null<Listing> = __read(directory, now);
		return fresh != null && fresh.names.exists(name);
	}

	private function __read(directory:String, now:Float):Null<Listing> {
		var entries:Array<String> = null;
		try {
			entries = sys.FileSystem.readDirectory(directory);
		} catch (_:Dynamic) {}

		// hxcpp answers null rather than throwing for a directory it cannot
		// open.
		if (entries == null) {
			__listings.remove(directory);
			return null;
		}

		var names:StringMap<Bool> = new StringMap();
		for (entry in entries) {
			names.set(entry, true);
		}

		if (!__listings.exists(directory)) {
			if (__size >= LIMIT) {
				__listings = new StringMap();
				__size = 0;
			}
			__size++;
		}

		var listing:Listing = {names: names, at: now};
		__listings.set(directory, listing);
		return listing;
	}
}

private typedef Listing = {
	var names:StringMap<Bool>;
	var at:Float;
}
#end
