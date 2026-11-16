/* Force-included before every host-test translation unit: the Zephyr toolchain
 * attributes and Kconfig values the firmware sources expect. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define __packed __attribute__((__packed__))
#define __aligned(x) __attribute__((__aligned__(x)))
#define BUILD_ASSERT(c, msg) _Static_assert(c, msg)
#define CONFIG_SDMMC_VOLUME_NAME "SD"
#define CONFIG_LOG_DEFAULT_LEVEL 3
