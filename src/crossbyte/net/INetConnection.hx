package crossbyte.net;

import crossbyte.io.ByteArrayInput;
import crossbyte.net.Protocol;
import crossbyte.io.ByteArray;

/**
 * Common connection contract shared by the concrete CrossByte stream transports.
 *
 * `INetConnection` exposes lightweight callbacks rather than event dispatch for
 * the hot path. `onData` receives a readable `ByteArrayInput`, while `onReady`,
 * `onClose`, and `onError` report lifecycle changes.
 */
interface INetConnection {
	/** Remote peer address. */
	public var remoteAddress(get, never):String;
	/** Remote peer port. */
	public var remotePort(get, never):Int;
	/** Local bound address. */
	public var localAddress(get, never):String;
	/** Local bound port. */
	public var localPort(get, never):Int;
	/** Transport protocol implemented by this connection. */
	public var protocol:Protocol;
	/** `true` after the transport is connected and usable. */
	public var connected(get, never):Bool;
	/** Enables or disables delivery to `onData`. */
	public var readEnabled(get, set):Bool;
	/** Timestamp of the most recent inbound payload, in CrossByte uptime seconds. */
	public var inTimestamp(default, null):Float;
	/** Timestamp of the most recent outbound payload, in CrossByte uptime seconds. */
	public var outTimestamp(default, null):Float;
	/** Called when incoming data is available. */
	public var onData(get, set):ByteArrayInput->Void;
	/** Called when the connection closes. */
	public var onClose(get, set):Reason->Void;
	/** Called when the transport reports an error. */
	public var onError(get, set):Reason->Void;
	/** Called once the connection becomes ready for I/O. */
	public var onReady(get, set):Void->Void;
	/** Exposes the concrete transport wrapper for transport-specific escapes. */
	public function expose():Transport;
	/** Sends a payload over the active transport. */
	public function send(data:ByteArray):Void;
	/** Closes the connection. */
	public function close():Void;
}
