#pragma once
#include <stdint.h>

#ifndef MIN
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#endif

int64_t k_uptime_get(void);
