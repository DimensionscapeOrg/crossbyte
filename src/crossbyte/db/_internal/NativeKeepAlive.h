#pragma once

bool crossbyte_db_keepalive_set(Dynamic socket, bool on, int idle, int interval, int count);
Array<int> crossbyte_db_keepalive_state(Dynamic socket);
