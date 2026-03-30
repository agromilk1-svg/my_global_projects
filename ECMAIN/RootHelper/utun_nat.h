#ifndef UTUN_NAT_H
#define UTUN_NAT_H

#include <stdint.h>
#include <stdbool.h>

void start_utun_nat(void);
void stop_utun_nat(void);

extern char g_utun_ifname[20];

#endif
