#pragma once
#include <stdio.h>

/* LOG_WRN is counted so a test can tell that a warning path ran. */
extern int log_warn_count;

#define LOG_MODULE_REGISTER(...)
#define LOG_ERR(...) (fprintf(stderr, "ERR: " __VA_ARGS__), fputc('\n', stderr))
#define LOG_WRN(...) ((void) log_warn_count++)
#define LOG_INF(...) ((void) 0)
#define LOG_DBG(...) ((void) 0)
