package crossbyte._internal.system.timer;

interface ITimer{
    public var size(get, never):Int;
	public var isEmpty(get, never):Bool;	
	public var time(get, never):Float;
	public final startTime:Float;
}