package crossbyte.utils;
import crossbyte.ds.Stack;

/**
 * ...
 * @author Christopher Speciale
 */

/**
* ObjectPool is a generic object pool class.
* It helps in reusing objects efficiently by managing a pool of reusable instances.
*
* @param T The type of objects to be pooled.
*/
class ObjectPool<T>
{
	private var __pool:Array<ObjectBucket<T>>;
	private var __available:Stack<Int>;
	private var __free:Stack<Int>;

	/**
	 * A factory function that creates new instances of the pooled objects.
	 * This function is used to populate the pool and to create new objects when needed.
	 */
	public var objectFactory:Void->T;

	/**
	 * A function to reset objects before they are released back to the pool.
	 * This function can be used to clear or initialize the state of objects.
	 */
	public var resetFunction:T->Void;

	/**
	 * Creates a new object pool.
	 *
	 * @param objectFactory The function to create new instances of the pooled objects.
	 * @param length Optional initial size of the pool.
	 */
	public function new(objectFactory:Void->T, ?resetFunction:T->Void, ?length:Int)
	{
		__pool = [];
		this.objectFactory = objectFactory;

		this.resetFunction = resetFunction;

		__free = new Stack();

		if (length != null)
		{
			__populate(length);
			__available = new Stack(length);
			return;
		}

		__available = new Stack();
	}

	private function __populate(len:Int):Void
	{
		for (i in 0...len)
		{
			var object:T = factory();
			__newElement(object);
			__available.push(len);

		}
	}

	private function __newElement(obj:T):Void
	{
		var len:Int = __pool.length;
		var element:ObjectBucket = new ObjectBucket(obj, len);
		__pool.push(element);
	}

	/**
	 * Acquires an object from the pool.
	 * If no objects are available, it creates a new one using the factory function.
	 *
	 * @return The acquired object.
	 */
	public function acquire():T
	{
		var nextAvailableIndex:Null<Int> = __available.pop();
		if (nextAvailableIndex != null)
		{
			return __getObject(nextAvailableIndex);
		}
		else {
			// Handle case where no objects are available
			// Example: Expand pool
			var newObj:T = objectFactory();
			__newElement(newObj);
			__free.push(__pool.length - 1);

			return newObj();
		}
	}

	private function __getObject(index:Int):T
	{
		var element:ObjectBucket = __pool[index];
		__free.push(index);
		return element.value;
	}

	/**
	 * Releases an object back to the pool.
	 *
	 * @param obj The object to release.
	 */
	public function release(obj:T):Void
	{
		var index:Int = __free.pop();
		__available.push(index);
		__pool[index].value = obj;

		if (resetFunction != null)
		{
			resetFunction(obj);
		}
	}
}

class ObjectBucket<T>
{
	public var index:Int;
	public var value:T;

	private function new(value:T, index:Int)
	{
		this.index = index;
		this.value = value;
	}
}