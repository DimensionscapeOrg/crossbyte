package crossbyte;

@:forward
@:generic
abstract TypedObject<T>(T) from T to T from Dynamic to Dynamic{
    public function new<T>(create:Void->T){
        this = create();
    }
}