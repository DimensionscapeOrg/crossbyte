package crossbyte.core;

enum MainLoopType{
    DEFAULT;
    POLL;
    CUSTOM(loop:Void->Void);
}