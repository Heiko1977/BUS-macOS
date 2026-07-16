#include "EnergySamplerBridge.h"
#include <libproc.h>
#include <sys/resource.h>
#include <string.h>

int bs_list_all_pids(int32_t *buffer, int max_count) {
    if (buffer == NULL || max_count <= 0) return 0;
    int bytes = proc_listallpids(buffer, max_count * (int)sizeof(int32_t));
    if (bytes <= 0) return 0;
    return bytes / (int)sizeof(int32_t);
}

int bs_process_usage(int32_t pid, BSProcessUsage *usage) {
    if (usage == NULL || pid <= 0) return 0;
    struct rusage_info_v4 ri;
    memset(&ri, 0, sizeof(ri));
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;

    usage->pid = pid;
    usage->user_time_ns = ri.ri_user_time;
    usage->system_time_ns = ri.ri_system_time;
    usage->disk_read_bytes = ri.ri_diskio_bytesread;
    usage->disk_write_bytes = ri.ri_diskio_byteswritten;
    usage->idle_wakeups = ri.ri_pkg_idle_wkups;
    usage->interrupt_wakeups = ri.ri_interrupt_wkups;
    return 1;
}

int bs_process_name(int32_t pid, char *buffer, int buffer_size) {
    if (buffer == NULL || buffer_size <= 0 || pid <= 0) return 0;
    return proc_name(pid, buffer, (uint32_t)buffer_size);
}
