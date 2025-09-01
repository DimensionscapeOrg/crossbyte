package crossbyte._internal.system.timer;

enum abstract ResumePolicy(Int) from Int to Int{
	var KeepPhase = 0;
	var FromNow = 1;
}