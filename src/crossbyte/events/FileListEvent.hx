package crossbyte.events;

import crossbyte.events.Event;
import crossbyte.io.File;

/**
 * ...
 * @author Christopher Speciale
 */
class FileListEvent extends Event {
	public static inline var DIRECTORY_LISTING:String = "directoryListing";

	public var files(default, null):Array<File>;

	public function new(type:String, files:Array<File>) {
		super(type);

		this.files = files;
	}
}
