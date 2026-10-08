package crossbyte.events;

import crossbyte.ds.TypeCheck;
import utest.Assert;

/**
	The event-type constants say which event they carry, so a listener of
	the wrong type is refused where it is added. If they were plain Strings,
	`addEventListener` would take the type from the listener, so any
	listener would fit, and a wrong one would fail only when the event
	arrived.
**/
class EventTypesTest extends utest.Test {
	public function testAListenerOfTheWrongEventIsRefused():Void {
		var dispatcher = new EventDispatcher();
		Assert.notNull(TypeCheck.errorOf(dispatcher.addEventListener(TickEvent.TICK, (e:ProgressEvent) -> {})), "a ProgressEvent listener fit TICK");
		Assert.notNull(TypeCheck.errorOf(dispatcher.addEventListener(ProgressEvent.SOCKET_DATA, (e:IOErrorEvent) -> {})),
			"an IOErrorEvent listener fit SOCKET_DATA");
		Assert.notNull(TypeCheck.errorOf(dispatcher.addEventListener(IOErrorEvent.IO_ERROR, (e:TickEvent) -> {})), "a TickEvent listener fit IO_ERROR");
		Assert.notNull(TypeCheck.errorOf(dispatcher.addEventListener(ThreadEvent.PROGRESS, (e:TickEvent) -> {})), "a TickEvent listener fit PROGRESS");
		Assert.notNull(TypeCheck.errorOf(dispatcher.addEventListener(Event.CLOSE, (e:TickEvent) -> {})), "a TickEvent listener fit CLOSE");
	}

	/** What fits: the event itself, or any type it extends. **/
	public function testTheRightListenerAndItsSupertypesStillFit():Void {
		var dispatcher = new EventDispatcher();
		var delta:Float = -1;
		var heard:Int = 0;
		dispatcher.addEventListener(TickEvent.TICK, (e:TickEvent) -> delta = e.delta);
		dispatcher.addEventListener(TickEvent.TICK, (e:Event) -> heard++);
		dispatcher.addEventListener(Event.COMPLETE, (e:Event) -> heard++);
		dispatcher.dispatchEvent(new TickEvent(TickEvent.TICK, 0.25));
		dispatcher.dispatchEvent(new Event(Event.COMPLETE));

		Assert.equals(0.25, delta);
		Assert.equals(2, heard);
		// Still Strings where a String is asked for.
		var name:String = Event.COMPLETE;
		Assert.equals("complete", name);
		Assert.isTrue(TickEvent.TICK == "tick");
	}

	#if (sys && !(js || php))
	/**
		`ServerSocket` checks a listener against the type, as every other
		dispatcher does, rather than taking any listener (`Dynamic->Void`) for
		any type.
	**/
	public function testAServerSocketChecksItsListenersToo():Void {
		var server = new crossbyte.net.ServerSocket();
		Assert.notNull(TypeCheck.errorOf(server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ProgressEvent) -> {})),
			"a ProgressEvent listener fit a server's CONNECT");
		Assert.notNull(TypeCheck.errorOf(server.removeEventListener(ServerSocketConnectEvent.CONNECT, (e:ProgressEvent) -> {})),
			"a ProgressEvent listener fit a server's CONNECT on removal");
		Assert.isNull(TypeCheck.errorOf(server.addEventListener(ServerSocketConnectEvent.CONNECT, (e:ServerSocketConnectEvent) -> {})));
	}
	#end

	/**
		What an uncaught error came from is `Any`: read through a test and a
		cast, not straight off it.
	**/
	public function testAnUncaughtErrorsOriginIsReadThroughACast():Void {
		var event = new UncaughtErrorEvent(UncaughtErrorEvent.UNCAUGHT_ERROR, "boom", UncaughtErrorEvent.POSTED, "origin");
		Assert.notNull(TypeCheck.errorOf(event.origin.close()), "a method was called on an untyped origin");
		Assert.equals("origin", (cast event.origin : String));
	}
}
