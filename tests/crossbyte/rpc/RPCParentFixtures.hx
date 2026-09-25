package crossbyte.rpc;

import haxe.io.Bytes as Blob;

// Private to this module, as the alias above is: the classes that extend these
// and implement the contract below, in RPCContractTest, can name neither.
private typedef Count = Int;

/**
	Parents and a contract in a module of their own, naming their types by an
	import alias and a private typedef. What a class elsewhere reads of them
	-- a child's of its parent's recorded methods, a handler's or commands
	class's of its contract -- is read in that class's module, so it has to
	be written out in full: `Blob` as `haxe.io.Bytes`, `Count` as `Int`, and
	`Null<Count>` as `Null<Int>`, still optional on the wire.
**/
class BlobParentHandler extends RPCHandler {
	public function new() {}

	@:rpc public function echoBlob(data:Blob):Blob {
		return data;
	}

	@:rpc public function countOrNone(value:Null<Count>):Count {
		return value == null ? -1 : value + 1;
	}
}

class BlobParentCommands extends RPCCommands {
	public function new() {}

	@:rpc public function echoBlob(data:Blob):RPCResponse<Blob> {}

	@:rpc public function countOrNone(value:Null<Count>):RPCResponse<Count> {}
}

interface MeasuredContract {
	function measure(data:Blob, extra:Null<Count>):Count;
}
