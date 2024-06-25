package crossbyte.events;

/**
 * @author Christopher Speciale
 */
interface IEventDispatcher {
	public function dispatchEvent(event:Event):Bool;
}
