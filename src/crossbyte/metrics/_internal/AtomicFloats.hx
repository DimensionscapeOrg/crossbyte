package crossbyte.metrics._internal;

#if cpp
/**
	Lock-free arithmetic on the Floats of an array: how a metric is updated
	on hxcpp.

	A server updates a metric for every response it sends, and a lock there
	cost about 230ns a time, because acquiring an hxcpp `Mutex` enters and
	leaves a GC-free zone. These are the same updates as atomic instructions
	on the value itself, a compare-and-swap loop for an addition, an atomic
	load or store otherwise, which cost a few nanoseconds when nothing else
	is writing, and never wait for another thread to finish anything.

	The values are the elements of an ordinary `Array<Float>`, which is what
	makes this sound. hxcpp allocates every array's storage 8-byte aligned,
	the alignment a 64-bit atomic needs; and nothing between taking an
	element's address and finishing with it allocates or reaches a safe
	point, so the collector cannot move the array while an update is under
	way. Relaxed ordering: an update has to be counted exactly once, not
	ordered against anything else.

	Once made, an array used here is read and written only through here. A
	plain read racing one of these could see half an update; a plain write
	could lose one.
**/
@:noCompletion
class AtomicFloats {
	/** Adds `amount` to `cells[index]`. **/
	public static inline function add(cells:Array<Float>, index:Int, amount:Float):Void {
		// Named so that no Haxe local the arguments mention can be one of them.
		// The assertion is the layout this relies on: an atomic double that is
		// a double and nothing more, needing no stricter alignment than 8.
		untyped __cpp__("{ static_assert(sizeof(::std::atomic<double>) == sizeof(double) && alignof(::std::atomic<double>) <= 8, \"an atomic double is not laid out as a double\"); double _cbAmount = {2}; ::std::atomic<double> *_cbCell = reinterpret_cast< ::std::atomic<double> *>(((double *){0}->getBase()) + {1}); double _cbSeen = _cbCell->load(::std::memory_order_relaxed); while (!_cbCell->compare_exchange_weak(_cbSeen, _cbSeen + _cbAmount, ::std::memory_order_relaxed)) {} }",
			cells, index, amount);
	}

	/** The current value of `cells[index]`. **/
	public static inline function load(cells:Array<Float>, index:Int):Float {
		return (untyped __cpp__("reinterpret_cast< ::std::atomic<double> *>(((double *){0}->getBase()) + {1})->load(::std::memory_order_relaxed)", cells,
			index) : Float);
	}

	/** Replaces `cells[index]` with `value`. **/
	public static inline function store(cells:Array<Float>, index:Int, value:Float):Void {
		untyped __cpp__("reinterpret_cast< ::std::atomic<double> *>(((double *){0}->getBase()) + {1})->store({2}, ::std::memory_order_relaxed)", cells, index,
			value);
	}
}
#end
