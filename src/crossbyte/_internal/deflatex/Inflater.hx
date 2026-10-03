package crossbyte._internal.deflatex;

import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesInput;
import haxe.io.Eof;

/**
 * Inflates a raw deflate stream (RFC 1951): through zlib natively (hxcpp's),
 * on Node (its own) and on the jvm (`java.util.zip`), and elsewhere through
 * `haxe.zip.InflateImpl`.
 *
 * It carried a decoder of its own beside that, Huffman tables in balanced
 * trees, a 32K-entry window, which nothing called any more, but whose window
 * every `new Inflater()` still allocated and cleared, and a CRC it computed
 * over every result for gzip's sake. Inflating an 846-byte message cost 96 us
 * on Node, 66 of them in the constructor. gzip computes its CRC itself now.
 */
class Inflater {
	/**
		Bytes this will produce before giving up, or `0` for no limit.

		Deflate has no bound on how far input expands, a megabyte of zeros
		comes back as about a gigabyte, so anything inflating a stream it
		did not author wants a ceiling. The check sits inside the read loop
		rather than on the result, so the memory is never taken in the first
		place.
	**/
	public var maxOutputSize:Int = 0;

	public function new() {}

	/**
	 * Applies the inflate decompression on the supplied stream.
	 * @return Bytes with the uncompressed data
	 */
	public function decompress(stream:Bytes):Bytes {
		return inflate(new BytesInput(stream), false, maxOutputSize, "deflate");
	}

	/**
		Inflates the stream `input` is at, raw deflate, or zlib (RFC 1950)
		when `zlib` is set, its header parsed and its Adler-32 checked, and
		leaves `input` just past it, where gzip finds its trailer and any
		member after it.

		@param maxOutputSize Bytes to produce before giving up, or `0` for no
		       limit.
		@param format Names the format in what is thrown.
		@throws IOError The data is not a valid stream, or ends before the
		        stream does.
		@throws RangeError It would produce more than `maxOutputSize` bytes.
	**/
	public static function inflate(input:BytesInput, zlib:Bool, maxOutputSize:Int, format:String):Bytes {
		#if cpp
		return __inflateNative(input, zlib, maxOutputSize, format);
		#elseif nodejs
		return NodeZlib.inflate(input, zlib, maxOutputSize, format);
		#elseif ((java || jvm) && !macro)
		return JvmZlib.inflate(input, zlib, maxOutputSize, format);
		#else
		return __inflateHaxe(input, zlib, maxOutputSize, format);
		#end
	}

	#if cpp
	/**
		`inflate` through hxcpp's zlib, which every native build links for
		`haxe.zip` already. The pure Haxe `InflateImpl` took 64-88 µs for a
		437-byte WebSocket message and zlib takes 3.4-4.5 µs (the audit's
		InflatePerf): it allocated a 64 KB window and built its Huffman tables
		as objects for every call.

		zlib is given the stream's bytes only, not what follows the input's
		window in the array, and reports how much of them it read: the input
		is left there, just past the stream.
	**/
	@:noCompletion private static function __inflateNative(input:BytesInput, zlib:Bool, maxOutputSize:Int, format:String):Bytes {
		var data:haxe.io.BytesData = @:privateAccess input.b;
		var start:Int = @:privateAccess input.pos;
		var available:Int = @:privateAccess input.len;
		var source:Bytes = Bytes.ofData(data);
		var at:Int = start;

		if (start + available < source.length) {
			// A window that ends before its array: zlib reads to the array's end.
			source = source.sub(start, available);
			at = 0;
		}

		var end:Int = at + available;
		var first:Int = at;

		if (available <= 0) {
			throw new IOError("Invalid " + format + " data: the stream ends early");
		}
		var chunk:Bytes = Bytes.alloc(__chunkFor(available, maxOutputSize));
		var output:BytesBuffer = null;
		var produced:Int = 0;
		var stream:haxe.zip.Uncompress = new haxe.zip.Uncompress(zlib ? 15 : -15);

		try {
			while (true) {
				var result = stream.execute(source, at, chunk, 0);
				at += result.read;

				if (result.write > 0) {
					produced += result.write;

					if (maxOutputSize > 0 && produced > maxOutputSize) {
						throw new RangeError("Inflated stream exceeded " + maxOutputSize + " bytes");
					}

					if (result.done && output == null) {
						// The whole of it in one go: no buffer between.
						stream.close();
						__advance(input, at - first);
						return chunk.sub(0, result.write);
					}

					if (output == null) {
						output = new BytesBuffer();
					}

					output.addBytes(chunk, 0, result.write);
				}

				if (result.done) {
					break;
				}

				if (at >= end && result.write < chunk.length) {
					// Every byte read, the output not full, and no end yet.
					throw new IOError("Invalid " + format + " data: the stream ends early");
				}
			}
		} catch (e:String) {
			stream.close();

			if (at >= end && StringTools.startsWith(e, "ZLib Error -5")) {
				// Z_BUF_ERROR: no progress, every byte read, a stream cut short.
				throw new IOError("Invalid " + format + " data: the stream ends early");
			}

			throw new IOError("Invalid " + format + " data: " + e);
		} catch (e:Dynamic) {
			stream.close();
			throw e;
		}

		stream.close();
		__advance(input, at - first);
		return output == null ? Bytes.alloc(0) : output.getBytes();
	}

	/** Moves `input` on by `count` bytes, past what was inflated. **/
	@:noCompletion private static inline function __advance(input:BytesInput, count:Int):Void {
		@:privateAccess {
			input.pos += count;
			input.len -= count;
		}
	}

	/** An output chunk for `available` bytes of input: room for a typical expansion, at most 64 KB. **/
	@:noCompletion private static inline function __chunkFor(available:Int, maxOutputSize:Int):Int {
		var size:Int = available * 4 + 256;

		if (size > 65536) {
			size = 65536;
		}

		if (maxOutputSize > 0 && size > maxOutputSize + 1) {
			size = maxOutputSize + 1;
		}

		return size;
	}
	#end

	/** `inflate` by `haxe.zip.InflateImpl`, in Haxe: where no zlib is at hand. **/
	@:noCompletion private static function __inflateHaxe(input:BytesInput, zlib:Bool, maxOutputSize:Int, format:String):Bytes {
		var output = new BytesBuffer();
		var buffer = Bytes.alloc(8192);
		var produced:Int = 0;

		// InflateImpl says what is wrong with a stream by throwing a String,
		// and that it ran out by letting Eof through, which is how a caller
		// that has to tell a damaged body from a bug could not: they reached
		// it as a bare string, and the HTTP client reported every one as an
		// unsupported content coding.
		try {
			var inflater = new haxe.zip.InflateImpl(input, zlib, zlib);
			while (true) {
				var read = inflater.readBytes(buffer, 0, buffer.length);

				produced += read;
				if (maxOutputSize > 0 && produced > maxOutputSize) {
					throw new RangeError("Inflated stream exceeded " + maxOutputSize + " bytes");
				}

				output.addBytes(buffer, 0, read);
				if (read < buffer.length) {
					break;
				}
			}
		} catch (e:Eof) {
			throw new IOError("Invalid " + format + " data: the stream ends early");
		} catch (e:String) {
			throw new IOError("Invalid " + format + " data: " + e);
		}

		return output.getBytes();
	}

	/**
	 * Applies inflate decompression on the supplied bytes.
	 * @return Decompressed output
	 */
	public static function apply(stream:Bytes, maxOutputSize:Int = 0):Bytes {
		var inflater = new Inflater();
		inflater.maxOutputSize = maxOutputSize;
		return inflater.decompress(stream);
	}
}
