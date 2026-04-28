package crossbyte.core;

/** Selects how a `CrossByte` instance advances its main loop. */
enum MainLoopType {
	/** Uses CrossByte's default runtime-selected loop. */
	DEFAULT;
	/** Uses the poll-driven loop implementation. */
	POLL;
	/** Uses a caller-provided loop callback. */
	CUSTOM(loop:Void->Void);
}
