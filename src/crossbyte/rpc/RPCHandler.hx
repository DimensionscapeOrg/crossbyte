package crossbyte.rpc;

// Built for every target, JavaScript included: the portable suite runs RPC on
// Node and in a browser.

import crossbyte.Future;
import crossbyte.rpc._internal.RPCFrame;
import crossbyte.rpc._internal.RPCWire;
import crossbyte.io.ByteArrayInput;

/**
	`RPCHandler` is the inbound implementation surface for CrossByte RPC sessions.

	A handler can be defined in two ways:

	- Manual mode: declare `@:rpc` methods directly on the subclass.
	- Contract mode: implement a single shared contract interface whose methods use
	  plain logical return types. The handler methods should match that interface
	  directly; unlike `RPCCommands`, handlers do not use `RPCResponse<T>` in their
	  method signatures.

	In contract mode, the shared interface can be used by `@:rpcContract(Contract)`
	on the command side, while the handler simply `implements Contract`.

	A handler method that throws answers its call with an error and leaves the
	connection up. Throw an `RPCError` for a failure the caller should see: its
	message is the caller's answer. Anything else reaches the caller as
	`RPCError.INTERNAL_MESSAGE`, and `RPCSession.onHandlerError` is told what
	it was. A call this side cannot take (for a method it has not got, or
	whose arguments do not read) is answered saying so if it is a request,
	and dropped if it is one-way, and the connection carries on: see
	`RPCSession.onUnreadableFrame`. Only a frame too long to trust ends it. A
	handler that writes its own `dispatch` decodes and calls in one place, so
	whatever that throws still ends the connection.

	A method can answer later: declared to return `Future<T>` instead of `T`,
	its caller is answered once the future completes (at once if it has, on
	the session's thread in any case), and a failure is answered as a throw
	is. The caller's side and the wire are the same as for `T`. A session
	limits how many calls may wait at once; see `RPCSession.maxCallsWaiting`.

	Override `beforeCall` to decide on each call before it runs (to
	authorize it, rate limit it, or refuse one too large) and `afterCall` to
	see how it went, in one place rather than in every method. A handler that
	overrides neither pays nothing for them.

	A handler can extend another. The subclass answers its parent's methods
	as well as its own, a contract method can be implemented by an ancestor,
	and hooks overridden in a shared base class apply to every handler built
	on it.

	One handler can serve any number of sessions: a server with one room,
	one queue or one world makes one handler and gives it to the session of
	every client it accepts. Each call is answered on the connection it came
	in on, and `session` says, while a method runs, whose call it is.
**/
@:autoBuild(crossbyte.rpc._internal.RPCHandlerMacro.build())
@:access(crossbyte.net.Socket)
@:access(crossbyte.rpc.RPCSession)
@:access(crossbyte.rpc.RPCCommands)
abstract class RPCHandler {
	public static inline final MAX_FRAME_LEN:Int = 8 * 1024 * 1024;

	/**
		The session whose call is running, while one is: a method reads it to
		tell its callers apart: `session.data` for what the application
		keeps per client, `session.commands` to call that client back, and
		`session.connection` for where it is. `null` between calls.

		So one handler given to several sessions answers each call on the
		connection it came in on, rather than every call on the last session's
		connection, where one client's answer would go to another.

		A method that answers later, with a `Future`, is answered on its
		caller's connection whatever `session` says by then. Code that needs
		the caller after its method has returned keeps `session` itself.
	**/
	public var session(get, never):RPCSession<Dynamic, Dynamic>;

	// The session whose call is being dispatched, set by that session for as
	// long as it dispatches to this handler, and where its frame ends: the
	// generated decoders read no further. Neither is the handler's own between
	// calls, since it may serve any number of sessions.
	@:noCompletion private var this_session:RPCSession<Dynamic, Dynamic>;
	@:noCompletion private var this_frameEnd:Int = RPCWire.NO_FRAME_END;

	@:noCompletion private inline function get_session():RPCSession<Dynamic, Dynamic> {
		return this_session;
	}

	abstract public function dispatch(op:Int, input:ByteArrayInput, requestId:Int):Void;

	/**
		The fingerprint of the methods this handler answers, `RPCOps.fingerprint`
		of their ops: what a session's hello says it answers. Generated with a
		generated `dispatch`; 0 for one written by hand, which says nothing.
	**/
	@:noCompletion public function __rpc_fingerprint():Int {
		return 0;
	}

	/**
		Called before each inbound call, before its arguments are read, with
		the method's name, the request's id (0 for a one-way call), and
		the bytes its arguments take. Return `null` to let the call run, or an
		`RPCError` to refuse it: a request is answered with the error's
		message, and a one-way call is dropped. A refusal is not reported to
		`RPCSession.onHandlerError`, since this made it.

		The calls are generated only into a handler that overrides this, or
		whose ancestor does; one that does not pays nothing for it. One that
		does calls it on every inbound call, so keep it cheap. Refusing by
		returning, not throwing, keeps a flood of refusals from costing an
		exception each.

		What it throws counts as the call failing: the caller is answered with
		`RPCError.INTERNAL_MESSAGE`, and the error goes to
		`RPCSession.onHandlerError`.
	**/
	public function beforeCall(method:String, requestId:Int, payloadSize:Int):Null<RPCError> {
		return null;
	}

	/**
		Called after each call `beforeCall` let through, once its method has
		run and its answer, if it has one, has been sent. `error` is `null`
		when the method returned, and what it threw when it did not, as a
		`haxe.Exception`: what was thrown, if it was one (an `RPCError`, say)
		and otherwise a `haxe.ValueException` holding it in its `value`. It is
		not given the result: handing over an `Int` or a `Float` as `Dynamic`
		would allocate on every call.

		Generated only into a handler that overrides it, or whose ancestor
		does. What it throws goes to `RPCSession.onHandlerError` and changes
		nothing else.
	**/
	public function afterCall(method:String, requestId:Int, error:Null<haxe.Exception>):Void {}

	/**
		What a handler method throwing becomes, once its arguments have been
		read: an error answer to a request, and a report on this side of
		whatever the caller is not told.

		The frame was sound, only the method failed, so the read goes on at
		the next one rather than ending the connection and failing every call
		still waiting on it.
	**/
	@:noCompletion private function __rpc_fail(op:Int, method:String, requestId:Int, error:haxe.Exception):Void {
		final session = this_session;
		if (session != null) {
			session.__callFailed(op, method, requestId, error, true);
		}
	}

	/**
		A call, from the generated dispatch, for an op this handler has no
		method for: a request is answered `RPCError.UNKNOWN_METHOD_MESSAGE`,
		a one-way call dropped, and `RPCSession.onUnreadableFrame` told. It
		threw, and the connection ended.
	**/
	@:noCompletion private function __rpc_unknown(op:Int, requestId:Int):Void {
		final session = this_session;
		if (session != null) {
			session.__unknownCall(op, requestId);
		}
	}

	/**
		A call whose arguments did not read, from its generated decoder: a
		request is answered `RPCError.UNREADABLE_MESSAGE`, a one-way call
		dropped, and `RPCSession.onUnreadableFrame` told.
	**/
	@:noCompletion private function __rpc_unreadable(op:Int, requestId:Int, error:Dynamic):Void {
		final session = this_session;
		if (session != null) {
			session.__unreadableCall(op, requestId, false, error);
		}
	}

	/**
		Whether a call to a method that answers with a future may run. Not
		when its session already has `maxCallsWaiting` calls waiting: then a
		request is answered `RPCError.BUSY_MESSAGE` and a one-way call dropped,
		before the method runs, as a `beforeCall` refusal is.
	**/
	@:noCompletion private function __rpc_mayWait(op:Int, requestId:Int):Bool {
		final session = this_session;
		if (session == null || !session.__atCallLimit()) {
			return true;
		}
		if (requestId != 0) {
			session.__sendCompiledError(op, requestId, RPCError.BUSY_MESSAGE);
		}
		return false;
	}

	/**
		Settles a call whose method answered with `future` (not complete yet,
		or failed) once it completes, on the session's thread: `answer` sends
		its value, a failure is answered as a throw is, and `afterCall` is told
		then, not when the method returned.

		Answered on the session the call came from, which is kept here: by the
		time the future completes, this handler may be running another
		session's call. And only while that session's connection is the one
		the call came in on. One that has ended gets nothing, and neither does
		the next peer of a connection that takes another (a `LocalConnection`
		listening again), which could have a call of its own waiting under
		the old one's id.
	**/
	@:noCompletion private function __rpc_later<T>(op:Int, method:String, requestId:Int, future:Future<T>,
			answer:(RPCSession<Dynamic, Dynamic>, T) -> Void, hooked:Bool):Void {
		final session = this_session;
		final epoch:Int = session.__epoch;
		final settle = function(settled:Future<T>):Void {
			var failure:Null<haxe.Exception> = null;
			final answerable:Bool = requestId != 0 && session.__isCurrent(epoch);
			if (settled.succeeded) {
				if (answerable) {
					try {
						answer(session, settled.result);
					} catch (error:haxe.Exception) {
						failure = error;
						session.__callFailed(op, method, requestId, error, true);
					}
				}
			} else {
				failure = RPCSession.__failureOf(settled);
				session.__callFailed(op, method, requestId, failure, answerable);
			}
			if (hooked) {
				try {
					afterCall(method, requestId, failure);
				} catch (error:haxe.Exception) {
					session.__reportHandlerError(op, method, error);
				}
			}
		};
		session.__settleOnThisThread(future, settle);
	}

	/** The frame an answer to `requestId` is written into, begun: `session`'s, the one the call came from. **/
	@:noCompletion private inline function __rpc_frame(session:RPCSession<Dynamic, Dynamic>, room:Int, op:Int, requestId:Int):RPCFrame {
		return session.__takeFrame(room, RPCWire.FLAG_RESPONSE, op, requestId);
	}

	/** Gives back an answer's frame its value could not be written into: a null inside an array or a structure. **/
	@:noCompletion private inline function __rpc_dropFrame(session:RPCSession<Dynamic, Dynamic>, framed:RPCFrame):Void {
		session.__sent(framed);
	}

	/** Sends the answer the generated code has framed, on the session it was framed for. **/
	@:noCompletion private inline function __rpc_answerOn(session:RPCSession<Dynamic, Dynamic>, framed:RPCFrame):Void {
		session.__sendAnswer(framed);
	}

	/** Answers a request `beforeCall` refused; a refused one-way call has nobody to tell. **/
	@:noCompletion private function __rpc_refuse(op:Int, requestId:Int, refusal:RPCError):Void {
		if (requestId != 0 && this_session != null) {
			this_session.__sendCompiledError(op, requestId, refusal.message != null ? refusal.message : RPCError.INTERNAL_MESSAGE);
		}
	}

	/** `afterCall` threw: the call is over, so all there is to do is say so. **/
	@:noCompletion private function __rpc_report(op:Int, method:String, error:haxe.Exception):Void {
		if (this_session != null) {
			this_session.__reportHandlerError(op, method, error);
		}
	}

	/**
		Built-in heartbeat/system ping. This stays on the handler surface and should not
		be declared inside shared RPC contract interfaces.
	**/
	abstract public function ping():Void;
}
