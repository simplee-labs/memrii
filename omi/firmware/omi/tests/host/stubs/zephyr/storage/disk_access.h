#pragma once
#include <stdint.h>

#define DISK_IOCTL_CTRL_SYNC 1
#define DISK_IOCTL_GET_SECTOR_COUNT 2

int disk_access_read(const char *pdrv, uint8_t *buf, uint32_t start, uint32_t n);
int disk_access_write(const char *pdrv, const uint8_t *buf, uint32_t start, uint32_t n);
int disk_access_ioctl(const char *pdrv, uint8_t cmd, void *buff);
