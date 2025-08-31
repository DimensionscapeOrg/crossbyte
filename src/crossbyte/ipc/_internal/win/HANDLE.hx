package crossbyte.ipc._internal.win;

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
