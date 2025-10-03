package crossbyte.ds;

import haxe.extern.EitherType;
import haxe.Constraints.Function;

typedef SwitchCase = {
	var key:EitherType<String, Int>;
	var handler:Function;
}