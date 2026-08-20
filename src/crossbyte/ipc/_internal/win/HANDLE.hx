package crossbyte.ipc._internal.win;

// Not built for the browser: inter-process channels and native handle types have no counterpart in a page.
#if !js

import crossbyte.ipc._internal.VoidPointer;

/**
 * ...
 * @author Christopher Speciale
 */
abstract HANDLE(VoidPointer) to VoidPointer {
	@:from
	static inline function fromPointer(ptr:VoidPointer):HANDLE {
		return cast ptr;
	}
}
#end
