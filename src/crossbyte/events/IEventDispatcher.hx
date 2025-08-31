package crossbyte.events;

/**
 * @author Christopher Speciale
 */
interface IEventDispatcher {
	public function dispatchEvent<T:Event>(event:T):Bool;
}
