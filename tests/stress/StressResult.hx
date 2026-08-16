package stress;

/**
 * Outcome of one stress case.
 */
typedef StressResult = {
	/**
	 * Case name, shown in the report.
	 */
	var name:String;

	/**
	 * Whether every invariant held.
	 */
	var passed:Bool;

	/**
	 * Observed values, printed whether the case passes or fails so a run
	 * log shows what was actually exercised rather than just a verdict.
	 */
	var details:Array<String>;
}
