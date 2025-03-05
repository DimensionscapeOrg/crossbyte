package crossbyte.rpc;

import crossbyte.PrimitiveValue;
import haxe.ds.StringMap;

abstract RPCHeader(StringMap<PrimitiveValue>) {
    public inline function new(){
        this = new StringMap();
    }

    /**
     * Sets a header value.
     *
     * @param key The header key.
     * @param value The value to associate with the key (wrapped in a HeaderPrimitive).
     */
     public function addHeader(key:String, value:PrimitiveValue):Void {
        this.set(key, value);
    }

    public function removeHeader(key:String):PrimitiveValue{
        return this.remove(key);
    }

    public function getHeader(key:String):PrimitiveValue{
        return this.get(key);
    }
}