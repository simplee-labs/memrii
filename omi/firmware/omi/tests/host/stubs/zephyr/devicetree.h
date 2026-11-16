#pragma once
#include <stdint.h>

/* retained.c finds its region through devicetree; tests point it at a plain buffer. */
extern uint8_t fake_retained_region[4096];

#define DT_NODELABEL(x) x
#define DT_PARENT(x) x
#define DT_REG_ADDR(x) ((uintptr_t) fake_retained_region)
#define DT_REG_SIZE(x) 4096
