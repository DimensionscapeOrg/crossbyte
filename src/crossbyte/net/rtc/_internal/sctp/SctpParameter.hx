package crossbyte.net.rtc._internal.sctp;

import crossbyte.io.ByteArray;
import crossbyte.io.Endian;

/**
	A type/length/value parameter, as INIT and INIT ACK carry them.

	The third place in this stack with the same shape and the same padding rule:
	the length counts the four byte header and the value and not the padding,
	while the next parameter still begins on a four byte boundary. STUN
	attributes work this way, SCTP chunks work this way, and so do these.

	Reusing the rule is not an accident of the protocols -- it is what lets a
	receiver skip something it does not recognise and carry on, which is the
	only reason either protocol can be extended without breaking every existing
	implementation.
**/
class SctpParameter {
	public static inline var HEADER_LENGTH:Int = 4;

	/** The opaque blob a server hands out in INIT ACK to be echoed back. **/
	public static inline var STATE_COOKIE:Int = 7;

	/** Says the sender understands partial reliability, which WebRTC uses. **/
	public static inline var FORWARD_TSN_SUPPORTED:Int = 0xC000;

	/** Lists the chunk types a sender understands beyond the base protocol. **/
	public static inline var SUPPORTED_EXTENSIONS:Int = 0x8008;

	public var type(default, null):Int;
	public var value(default, null):ByteArray;

	public function new(type:Int, ?value:ByteArray) {
		this.type = type;
		this.value = value != null ? value : new ByteArray();
	}

	/**
		What to do with a parameter nobody here recognises.

		The instruction is in the top two bits of the type, the same idea SCTP
		puts in a chunk type. A receiver that stopped at every unknown parameter
		could never talk to a newer peer, and one that skipped every unknown
		parameter silently could never be told it had missed something
		mandatory.
	**/
	public var unknownAction(get, never):SctpParameterAction;

	private function get_unknownAction():SctpParameterAction {
		return switch ((type >> 14) & 0x03) {
			case 0: STOP;
			case 1: STOP_AND_REPORT;
			case 2: SKIP;
			default: SKIP_AND_REPORT;
		}
	}

	/** Writes a list into `out`, padded as the rule requires. **/
	public static function writeAll(out:ByteArray, parameters:Array<SctpParameter>):Void {
		if (parameters == null) {
			return;
		}

		out.endian = Endian.BIG_ENDIAN;

		for (parameter in parameters) {
			out.writeShort(parameter.type);
			out.writeShort(HEADER_LENGTH + parameter.value.length);

			if (parameter.value.length > 0) {
				out.writeBytes(parameter.value, 0, parameter.value.length);
			}

			var padding:Int = (4 - (parameter.value.length % 4)) % 4;

			for (_ in 0...padding) {
				out.writeByte(0);
			}
		}
	}

	/**
		Reads a list, stopping at anything that will not fit.

		A parameter claiming more than the buffer holds ends the walk rather
		than being guessed at. What parsed before it is still good.
	**/
	public static function readAll(bytes:ByteArray, offset:Int, limit:Int):Array<SctpParameter> {
		var parameters:Array<SctpParameter> = [];

		if (bytes == null) {
			return parameters;
		}

		if (limit > bytes.length) {
			limit = bytes.length;
		}

		bytes.endian = Endian.BIG_ENDIAN;
		var at:Int = offset;

		while (at + HEADER_LENGTH <= limit) {
			bytes.position = at;

			var type:Int = bytes.readUnsignedShort();
			var length:Int = bytes.readUnsignedShort();

			if (length < HEADER_LENGTH || at + length > limit) {
				break;
			}

			var valueLength:Int = length - HEADER_LENGTH;
			var value = new ByteArray();

			if (valueLength > 0) {
				bytes.readBytes(value, 0, valueLength);
			}

			value.position = 0;
			parameters.push(new SctpParameter(type, value));

			at += length + ((4 - (length % 4)) % 4);
		}

		return parameters;
	}

	/** The first parameter of `type` in a list, or null. **/
	public static function find(parameters:Array<SctpParameter>, type:Int):Null<SctpParameter> {
		if (parameters == null) {
			return null;
		}

		for (parameter in parameters) {
			if (parameter.type == type) {
				return parameter;
			}
		}

		return null;
	}
}

/** RFC 4960 section 3.2.1, the top two bits of a parameter type. **/
enum abstract SctpParameterAction(Int) {
	/** Stop processing and discard the whole chunk. **/
	var STOP = 0;

	/** Stop, discard, and report the unrecognised type. **/
	var STOP_AND_REPORT = 1;

	/** Skip this parameter and carry on. **/
	var SKIP = 2;

	/** Skip it, carry on, and report it. **/
	var SKIP_AND_REPORT = 3;
}
