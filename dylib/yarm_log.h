#pragma once

#import <os/log.h>

// Single os_log subsystem; tail with:
//   log stream --predicate 'subsystem == "com.maxbridgland.yarm"' --level debug
#define YARM_LOG_DECL static os_log_t _yarm_log(void) { \
    static os_log_t l; static dispatch_once_t once; \
    dispatch_once(&once, ^{ l = os_log_create("com.maxbridgland.yarm", "inject"); }); \
    return l; \
}

#define YARM_INFO(fmt, ...)  os_log_info(_yarm_log(), fmt, ##__VA_ARGS__)
#define YARM_DEBUG(fmt, ...) os_log_debug(_yarm_log(), fmt, ##__VA_ARGS__)
#define YARM_ERR(fmt, ...)   os_log_error(_yarm_log(), fmt, ##__VA_ARGS__)
