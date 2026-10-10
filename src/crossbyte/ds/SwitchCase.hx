package crossbyte.ds;

import haxe.extern.EitherType;
import haxe.Constraints.Function;

/**
	A case of `SwitchTable.make`: a key, a constant, and the handler it
	reaches. The keys of a table are of one type and its handlers take the
	same arguments, which `make` checks as it builds the table.
**/
typedef SwitchCase = {
	var key:EitherType<String, Int>;
	var handler:Function;
}
