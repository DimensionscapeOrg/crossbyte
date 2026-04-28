package crossbyte.sys;

/** Lifecycle states reported by `Task` instances. */
enum TaskState {
	/** Waiting in a queue and not yet running. */
	PENDING;
	/** Currently executing. */
	RUNNING;
	/** Finished successfully. */
	COMPLETED;
	/** Ended with an error. */
	FAILED;
	/** Cancelled before normal completion. */
	CANCELLED;
}
