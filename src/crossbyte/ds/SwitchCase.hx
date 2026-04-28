package crossbyte.ds;

import haxe.extern.EitherType;
import haxe.Constraints.Function;

/** Dispatch entry used by `SwitchTable` for string or integer keyed handlers. */
typedef SwitchCase = {
	var key:EitherType<String, Int>;
	var handler:Function;
}
