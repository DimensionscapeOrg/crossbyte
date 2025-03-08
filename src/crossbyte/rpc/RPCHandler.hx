package crossbyte.rpc;

@:autoBuild(crossbyte.rpc._internal.RPCHandlerMacro.build())
class RPCHandler {
    //@:generic 
    public function call<P1, P2, P3, P4, P5, P6, P7, P8>(type:CallSig<P1, P2, P3, P4, P5, P6, P7, P8>, a:P1, b:P2, c:P3, d:P4, e:P5, f:P6, g:P7, h:P8):Void {}
}

//@:generic
enum abstract CallSig<P1, P2, P3, P4, P5, P6, P7, P8>(Int) from Int to Int {}