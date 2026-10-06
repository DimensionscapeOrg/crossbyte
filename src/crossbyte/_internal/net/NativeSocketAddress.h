#pragma once

Dynamic crossbyte_socket_accept(Dynamic socket);
Array<int> crossbyte_socket_host_info(Dynamic socket);
Array<int> crossbyte_socket_peer_info(Dynamic socket);
int crossbyte_socket_send_to(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address);
int crossbyte_socket_recv_from(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address);
String crossbyte_socket_connect_error(Dynamic socket);
int crossbyte_socket_send_batch(Dynamic socket, Array<unsigned char> buffer, Array<int> spans, Array<Dynamic> targets, int first, int count);
Array<Dynamic> crossbyte_socket_select(Array<Dynamic> rs, Array<Dynamic> ws, Array<Dynamic> es, Dynamic timeout);
int crossbyte_socket_try_send(Dynamic socket, Array<unsigned char> buffer, int position, int length);
int crossbyte_socket_try_recv(Dynamic socket, Array<unsigned char> buffer, int position, int length);
int crossbyte_socket_try_send_to(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address);
int crossbyte_socket_try_recv_from(Dynamic socket, Array<unsigned char> buffer, int position, int length, Dynamic address);
void crossbyte_udp_ignore_unreachable(Dynamic socket);
bool crossbyte_udp_batch_supported();
Dynamic crossbyte_udp_batch_new(int capacity);
int crossbyte_udp_batch_capacity(Dynamic batch);
int crossbyte_udp_batch_receive(Dynamic socket, Dynamic batch, int max);
int crossbyte_udp_batch_take(Dynamic batch, int index, Dynamic address);
void crossbyte_udp_batch_copy(Dynamic batch, int index, Array<unsigned char> buffer, int position);
void crossbyte_udp_batch_free(Dynamic batch);
