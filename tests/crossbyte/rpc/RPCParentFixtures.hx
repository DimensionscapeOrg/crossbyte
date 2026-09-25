package crossbyte.rpc;

import haxe.io.Bytes;

/**
	Parents in a module of their own, naming a type this module imports and
	the module of the classes that extend them (RPCContractTest) does not.
	What a child reads of its parent's methods is recorded by the parent's
	build and read in the child's module, so it has to name its types in full.
**/
class BlobParentHandler extends RPCHandler {
	public function new() {}

	@:rpc public function echoBlob(data:Bytes):Bytes {
		return data;
	}
}

class BlobParentCommands extends RPCCommands {
	public function new() {}

	@:rpc public function echoBlob(data:Bytes):RPCResponse<Bytes> {}
}
