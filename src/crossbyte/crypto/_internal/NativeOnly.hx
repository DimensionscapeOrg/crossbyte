package crossbyte.crypto._internal;

import crossbyte.errors.IllegalOperationError;

/**
	What a native-only member throws on any other target: an
	`IllegalOperationError` naming the feature and the target it was asked on,
	so the error says why there and not merely that it failed.
**/
@:noCompletion
class NativeOnly {
	/** The target this build is for, as an error names it. **/
	public static inline final TARGET:String = #if (java || jvm) "the jvm" #elseif nodejs "Node" #elseif js "a browser" #elseif eval "the interpreter" #elseif neko "neko" #elseif hl "HashLink" #elseif php "PHP" #elseif python "Python" #elseif lua "Lua" #elseif cpp "this native build" #else "this target" #end;

	/** The error for `feature` asked for on this target. **/
	public static function error(feature:String):IllegalOperationError {
		return new IllegalOperationError(feature + " is only available natively (cpp), not on " + TARGET + ".");
	}
}
