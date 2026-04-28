package crossbyte.sys;

/** Lifecycle states reported by worker execution helpers. */
enum WorkerState {
	/** Not currently running work. */
	IDLE;
	/** Currently running work. */
	RUNNING;
	/** Finished successfully. */
	COMPLETED;
	/** Ended with an error. */
	FAILED;
	/** Cancelled before normal completion. */
	CANCELLED;
}
