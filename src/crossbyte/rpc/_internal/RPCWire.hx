package crossbyte.rpc._internal;

class RPCWire {
	public static inline final FLAG_REQUEST:Int = 0x01;
	public static inline final FLAG_RESPONSE:Int = 0x02;
	public static inline final FLAG_ERROR:Int = 0x04;
	public static inline final FLAG_RUNTIME:Int = 0x08;
	public static inline final MIN_PAYLOAD_LEN:Int = 5;
}
