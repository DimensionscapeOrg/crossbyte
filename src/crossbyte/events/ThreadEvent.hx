package crossbyte.events;

/**
 * ...
 * @author Christopher Speciale
 */
class ThreadEvent extends Event {
	public static inline var COMPLETE:String = "complete";
	public static inline var UPDATE:String = "update";
	public static inline var PROGRESS:String = "progress";
	public static inline var ERROR:String = "error";

	public var message:Dynamic;

	public function new(type:String, message:Dynamic = null) {
		super(type);

		this.message = message;
	}
}
