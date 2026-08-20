package crossbyte.ipc._internal;

// Not built for the browser: shared memory and IPC handles between OS processes.
#if !(js && !nodejs)

import cpp.Pointer;
import cpp.Void as CppVoid;

/**
 * ...
 * @author Christopher Speciale
 */
typedef VoidPointer = Pointer<CppVoid>;
#end
