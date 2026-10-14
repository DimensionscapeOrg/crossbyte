package crossbyte.utils;

/**
	One structured field of a log record, for the ordered form of
	`LogFields`: `{key: "port", value: 7000}`. The value is written as
	`Std.string` writes it, and null as JSON's `null`, or `""` in text.
**/
typedef LogField = {
	var key:String;
	var value:Dynamic;
}
