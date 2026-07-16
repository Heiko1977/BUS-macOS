#ifndef EnergySamplerBridge_h
#define EnergySamplerBridge_h

#include <stdint.h>
#include <stddef.h>

typedef struct {
    int32_t pid;
    uint64_t user_time_ns;
    uint64_t system_time_ns;
    uint64_t disk_read_bytes;
    uint64_t disk_write_bytes;
    uint64_t idle_wakeups;
    uint64_t interrupt_wakeups;
} BSProcessUsage;

int bs_list_all_pids(int32_t *buffer, int max_count);
int bs_process_usage(int32_t pid, BSProcessUsage *usage);
int bs_process_name(int32_t pid, char *buffer, int buffer_size);

#endif
