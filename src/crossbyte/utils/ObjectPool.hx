package crossbyte.utils;
import haxe.ds.ObjectMap;

/**
 * ...
 * @author Christopher Speciale
 */

abstract ObjectPool<T>(Array<T>)
{
	
	private static var __objectFactoryMap:ObjectMap<Array<Dynamic>, Void->Dynamic>;

	public var length(get, set):Int;
	public var factory(get, set):Void->T;

	public inline function new(objectFactory:Void->T)
	{
		this = new Array();
		__objectFactoryMap = new ObjectMap();
		__objectFactoryMap.set(this, objectFactory);
	}

	public inline function aquire():T
	{
		var object:T = this.pop();

		if (object == null)
		{
			object = factory();
		}
		return object;
	}

	public inline function release(obj: T): Void
	{
		this.push(obj);
	}

	public inline function clear(): Void
	{
		this = new Array();
	}

	public inline function dispose(): Void
	{
		__objectFactoryMap.remove(this);
	}

	private inline function set_length(value:Int):Int
	{
		if (this.length < value)
		{
			var factory:Function = __objectFactoryMap.get(this);
			//TODO error handling if not exists
			while (this.length < value)
			{
				this.push(factory());
			}
		}
		else if (this.length > value)
		{
			this.resize(value);
		}
		return value;
	}

	private inline function get_length():Int
	{
		return this.length;
	}

	private inline function set_factory(value:Void->T):Void->T
	{
		__objectFactoryMap.set(this, value);
		return value;
	}

	private inline function get_factory():Void->T
	{
		return __objectFactoryMap.get(this);
	}
}