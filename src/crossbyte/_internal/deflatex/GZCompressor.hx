package crossbyte._internal.deflatex;

import crossbyte._internal.deflatex.utils.BitsOutput;
import crossbyte.errors.IOError;
import crossbyte.errors.RangeError;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.BytesInput;
import haxe.io.Eof;

/**
 * Implements the gzip file format for storing DEFLATE-compressed streams.
 */
class GZCompressor {
	/*
	 * Compression methods
	 */
	private static final M_DEFLATE:Int = 8;

	/*
	 * Header flags
	 */
	private static final F_TEXT:Int = 1;
	private static final F_HCRC:Int = 2;
	private static final F_EXTRA:Int = 4;
	private static final F_NAME:Int = 8;
	private static final F_COMMENT:Int = 16;
	private static final F_RESERVED:Int = 0xE0;

	/**
	 * Reads a series of bytes from an input stream and
	 * executes a compression algorithm over them,
	 * returning the resulting stream.
	 * @param stream The input bytes of data to be compressed
	 * @return The output bytes of compressed data
	 */
	public static function compress(file_name:String, stream:Bytes):Bytes {
		// A name is only worth the header bytes when there is one to record.
		// The member is unnamed otherwise, which is what a gzip HTTP body
		// wants: there is no file, and inventing a name for one spends five
		// bytes per response saying so.
		var named:Bool = file_name != null && file_name.length > 0;

		var output:BitsOutput = new BitsOutput();
		output.writeByte(0x1f);
		output.writeByte(0x8b);
		output.writeByte(M_DEFLATE);
		output.writeByte(named ? F_NAME : 0);
		for (i in 0...6) {
			output.writeByte(0);
		}

		if (named) {
			output.writeString(file_name);
			output.writeByte(0);
		}

		var deflater:Deflater = new Deflater();
		var result:Bytes = deflater.compress(stream);
		output.write(result);

		var crc:CRC32 = new CRC32();
		crc.updateBytes(stream, 0, stream.length);
		output.writeInt32(crc.value);
		output.writeInt32(stream.length);

		return output.getBytes();
	}

	/**
		Inflates a gzip stream (RFC 1952): every member of it, in order.

		Each member's header is read in full -- an extra field, a name, a
		comment and a header CRC, which is checked -- and each member's CRC and
		length are checked against what it inflated to. Members follow one
		another as gzip writes them when files are concatenated, and are
		returned joined. Zero bytes after the last member are padding and are
		ignored; anything else there is refused, as Node's gunzip refuses it.

		It read a name and nothing else: a header with an extra field, a
		comment or a header CRC was refused as unsupported, and the trailer
		was taken to be the last eight bytes of the input, so a second member
		failed its CRC.

		@param maxOutputSize Bytes to produce before giving up, or `0` for no
		       limit, across all the members together. A gzip member says
		       nothing trustworthy about how far it expands, so a caller
		       inflating a stream it did not author wants to name a ceiling.
		@throws IOError The data is not gzip, or is damaged or cut short.
		@throws crossbyte.errors.RangeError It inflates past `maxOutputSize`.
	**/
	public static function decompress(stream:Bytes, maxOutputSize:Int = 0):Bytes {
		var input:BytesInput = new BytesInput(stream);
		var produced:Int = 0;
		var first:Bytes = null;
		var joined:BytesBuffer = null;
		try {
			while (true) {
				__readHeader(stream, input);

				// What the limit leaves for this member. Never 0, which the
				// inflater takes for no limit: a member arriving with nothing
				// left may still be empty, and is checked on the total below.
				var allowance:Int = 0;
				if (maxOutputSize > 0) {
					allowance = maxOutputSize - produced;
					if (allowance < 1) {
						allowance = 1;
					}
				}

				// Inflated where it lies, so the trailer is read from where
				// the deflate stream actually ends.
				var member:Bytes = Inflater.inflate(input, false, allowance, "gzip");

				var f_crc:Int = input.readInt32();
				var f_size:Int = input.readInt32();

				if (member.length != f_size) {
					throw new IOError("Invalid gzip data: " + member.length + " bytes where the trailer says " + f_size);
				}
				var check:CRC32 = new CRC32();
				check.updateBytes(member, 0, member.length);
				if (check.value != f_crc) {
					throw new IOError("Invalid gzip data: CRC " + StringTools.hex(check.value, 8) + " where the trailer says " + StringTools.hex(f_crc, 8));
				}

				produced += member.length;
				if (maxOutputSize > 0 && produced > maxOutputSize) {
					throw new RangeError("Inflated stream exceeded " + maxOutputSize + " bytes");
				}
				if (first == null) {
					first = member;
				} else {
					if (joined == null) {
						joined = new BytesBuffer();
						joined.add(first);
					}
					joined.add(member);
				}

				if (!__anotherMember(stream, input.position)) {
					break;
				}
			}
		} catch (e:Eof) {
			throw new IOError("Invalid gzip data: the stream ends early");
		}

		return joined != null ? joined.getBytes() : first;
	}

	/**
		Reads one member's header, leaving `input` at its deflate stream.
	**/
	@:noCompletion private static function __readHeader(stream:Bytes, input:BytesInput):Void {
		var start:Int = input.position;
		var id1:Int = input.readByte();
		var id2:Int = input.readByte();
		if (id1 != 0x1f || id2 != 0x8b) {
			throw new IOError(start == 0 ? "Invalid gzip data: no gzip header" : "Invalid gzip data: what follows a member is not another member");
		}
		var method:Int = input.readByte();
		if (method != M_DEFLATE) {
			throw new IOError("Invalid gzip data: compression method " + method);
		}
		var flags:Int = input.readByte();
		if ((flags & F_RESERVED) != 0) {
			throw new IOError("Invalid gzip data: reserved header flags " + flags);
		}
		// MTIME, XFL and OS: nothing to act on.
		input.read(6);

		if ((flags & F_EXTRA) != 0) {
			var length:Int = input.readUInt16();
			input.read(length);
		}
		if ((flags & F_NAME) != 0) {
			__skipString(input);
		}
		if ((flags & F_COMMENT) != 0) {
			__skipString(input);
		}
		if ((flags & F_HCRC) != 0) {
			// The low two bytes of the CRC-32 of the header before them.
			var headerCrc:CRC32 = new CRC32();
			headerCrc.updateBytes(stream, start, input.position - start);
			var expected:Int = input.readUInt16();
			if ((headerCrc.value & 0xFFFF) != expected) {
				throw new IOError("Invalid gzip data: the header CRC does not match");
			}
		}
	}

	@:noCompletion private static function __skipString(input:BytesInput):Void {
		while (input.readByte() != 0) {}
	}

	/**
		Whether another member starts at `at`: anything but zero padding is
		taken to be one, and its header read refuses it if it is not.
	**/
	@:noCompletion private static function __anotherMember(stream:Bytes, at:Int):Bool {
		for (i in at...stream.length) {
			if (stream.get(i) != 0) {
				return true;
			}
		}
		return false;
	}
}
