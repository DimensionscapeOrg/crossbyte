#pragma once

#include <hxcpp.h>

Dynamic crossbyte_socket_accept(Dynamic socket);
Array<int> crossbyte_socket_host_info(Dynamic socket);
Array<int> crossbyte_socket_peer_info(Dynamic socket);
int crossbyte_socket_send_to(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address);
int crossbyte_socket_recv_from(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address);
