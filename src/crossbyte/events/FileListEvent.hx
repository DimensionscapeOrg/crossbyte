package crossbyte.events;

import crossbyte.events.Event;
import crossbyte.io.File;

/** Event carrying a resolved file listing from an asynchronous directory query. */
class FileListEvent extends Event {
	public static inline var DIRECTORY_LISTING:String = "directoryListing";

	public var files(default, null):Array<File>;

	public function new(type:String, files:Array<File>) {
		super(type);

		this.files = files;
	}

	override public function clone():Event {
		var event = new FileListEvent(type, files);
		event.target = target;
		event.currentTarget = currentTarget;
		return event;
	}
}
