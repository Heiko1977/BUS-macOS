
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define OUTPUT_DIR "/Library/Application Support/BUS"
#define OUTPUT_FILE OUTPUT_DIR "/hardware.json"
#define OUTPUT_TMP OUTPUT_DIR "/hardware.json.tmp"
#define SAMPLE_SECONDS 2

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

typedef struct {
    bool valid;
    double value;
    char key[5];
    char type[5];
} SMCReading;

static volatile sig_atomic_t running = 1;

static void stop_handler(int signal_number) {
    (void) signal_number;
    running = 0;
}

static uint32_t fourcc(const char key[5]) {
    return ((uint32_t)(uint8_t)key[0] << 24)
         | ((uint32_t)(uint8_t)key[1] << 16)
         | ((uint32_t)(uint8_t)key[2] << 8)
         | ((uint32_t)(uint8_t)key[3]);
}

static void fourcc_string(uint32_t value, char out[5]) {
    out[0] = (char)((value >> 24) & 0xff);
    out[1] = (char)((value >> 16) & 0xff);
    out[2] = (char)((value >> 8) & 0xff);
    out[3] = (char)(value & 0xff);
    out[4] = '\0';
}

static bool smc_open(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSMC")
    );
    if (service == IO_OBJECT_NULL) {
        return false;
    }

    kern_return_t result = IOServiceOpen(
        service,
        mach_task_self(),
        0,
        connection
    );
    IOObjectRelease(service);
    return result == KERN_SUCCESS;
}

static bool smc_read_raw(
    io_connect_t connection,
    const char key_name[5],
    uint8_t bytes[32],
    uint32_t *size,
    char type[5]
) {
    SMCParamStruct input;
    SMCParamStruct output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));

    input.key = fourcc(key_name);
    input.data8 = SMC_CMD_READ_KEYINFO;

    size_t output_size = sizeof(output);
    kern_return_t result = IOConnectCallStructMethod(
        connection,
        KERNEL_INDEX_SMC,
        &input,
        sizeof(input),
        &output,
        &output_size
    );
    if (result != KERN_SUCCESS || output.result != 0) {
        return false;
    }

    input.keyInfo.dataSize = output.keyInfo.dataSize;
    input.data8 = SMC_CMD_READ_BYTES;
    output_size = sizeof(output);
    memset(&output, 0, sizeof(output));

    result = IOConnectCallStructMethod(
        connection,
        KERNEL_INDEX_SMC,
        &input,
        sizeof(input),
        &output,
        &output_size
    );
    if (result != KERN_SUCCESS || output.result != 0) {
        return false;
    }

    *size = output.keyInfo.dataSize;
    if (*size > 32) {
        return false;
    }

    memcpy(bytes, output.bytes, *size);
    fourcc_string(output.keyInfo.dataType, type);
    return true;
}

static double decode_smc(
    const uint8_t *bytes,
    uint32_t size,
    const char type[5],
    bool *ok
) {
    *ok = false;

    if (strcmp(type, "flt ") == 0 && size == 4) {
        uint32_t raw;
        memcpy(&raw, bytes, 4);
        raw = ntohl(raw);
        float value;
        memcpy(&value, &raw, 4);
        if (isfinite(value)) {
            *ok = true;
            return value;
        }
    }

    if ((strcmp(type, "sp78") == 0 || strcmp(type, "fp88") == 0)
        && size >= 2) {
        int16_t raw = (int16_t)ntohs(*(const uint16_t *)bytes);
        *ok = true;
        return (double)raw / 256.0;
    }

    if (strcmp(type, "ui8 ") == 0 && size >= 1) {
        *ok = true;
        return bytes[0];
    }

    if (strcmp(type, "ui16") == 0 && size >= 2) {
        *ok = true;
        return ntohs(*(const uint16_t *)bytes);
    }

    if (strcmp(type, "si16") == 0 && size >= 2) {
        *ok = true;
        return (int16_t)ntohs(*(const uint16_t *)bytes);
    }

    if (strcmp(type, "ui32") == 0 && size >= 4) {
        *ok = true;
        return ntohl(*(const uint32_t *)bytes);
    }

    if (strcmp(type, "si32") == 0 && size >= 4) {
        *ok = true;
        return (int32_t)ntohl(*(const uint32_t *)bytes);
    }

    return 0;
}

static SMCReading smc_read_first(
    io_connect_t connection,
    const char *keys[],
    size_t key_count,
    double minimum,
    double maximum
) {
    SMCReading reading;
    memset(&reading, 0, sizeof(reading));

    for (size_t index = 0; index < key_count; index++) {
        uint8_t bytes[32] = {0};
        uint32_t size = 0;
        char type[5] = {0};

        if (!smc_read_raw(connection, keys[index], bytes, &size, type)) {
            continue;
        }

        bool ok = false;
        double value = decode_smc(bytes, size, type, &ok);
        if (!ok || !isfinite(value) || value < minimum || value > maximum) {
            continue;
        }

        reading.valid = true;
        reading.value = value;
        strncpy(reading.key, keys[index], 4);
        reading.key[4] = '\0';
        strncpy(reading.type, type, 4);
        reading.type[4] = '\0';
        return reading;
    }

    return reading;
}

static double cf_number(CFDictionaryRef dict, CFStringRef key, bool *valid) {
    *valid = false;
    if (!dict) return 0;

    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return 0;

    double result = 0;
    if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result)) {
        *valid = true;
        return result;
    }
    return 0;
}

static bool cf_bool(CFDictionaryRef dict, CFStringRef key) {
    if (!dict) return false;
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value) return false;

    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        return CFBooleanGetValue((CFBooleanRef)value);
    }
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
        return number != 0;
    }
    return false;
}

static CFDictionaryRef battery_properties(void) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSmartBattery")
    );
    if (service == IO_OBJECT_NULL) {
        return NULL;
    }

    CFMutableDictionaryRef properties = NULL;
    kern_return_t result = IORegistryEntryCreateCFProperties(
        service,
        &properties,
        kCFAllocatorDefault,
        0
    );
    IOObjectRelease(service);

    if (result != KERN_SUCCESS) {
        if (properties) CFRelease(properties);
        return NULL;
    }
    return properties;
}

static void ensure_output_directory(void) {
    mkdir(OUTPUT_DIR, 0755);
    chmod(OUTPUT_DIR, 0755);
}

static void json_string(FILE *file, const char *value) {
    fputc('"', file);
    for (const char *cursor = value; *cursor; cursor++) {
        if (*cursor == '"' || *cursor == '\\') {
            fputc('\\', file);
        }
        fputc(*cursor, file);
    }
    fputc('"', file);
}

static void write_json(void) {
    CFDictionaryRef battery = battery_properties();

    bool voltage_valid = false;
    bool current_valid = false;
    double voltage_mv = cf_number(
        battery,
        CFSTR("Voltage"),
        &voltage_valid
    );
    double current_ma = cf_number(
        battery,
        CFSTR("Amperage"),
        &current_valid
    );

    bool charging = cf_bool(battery, CFSTR("IsCharging"));
    bool connected = cf_bool(battery, CFSTR("ExternalConnected"));

    double battery_power = 0;
    bool battery_power_valid = voltage_valid && current_valid;
    if (battery_power_valid) {
        battery_power = fabs(voltage_mv * current_ma / 1000000.0);
    }

    io_connect_t smc = IO_OBJECT_NULL;
    bool smc_available = smc_open(&smc);

    const char *input_power_keys[] = {
        "PDTR", "PSTR", "AC-W", "PIn ", "PINA", "DCPW"
    };
    const char *system_power_keys[] = {
        "PSTR", "PST0", "PCPT", "PMVR", "PSYS"
    };
    const char *battery_power_keys[] = {
        "B0AP", "B0PW", "BBAD", "B0AC"
    };

    SMCReading input_power = {0};
    SMCReading system_power = {0};
    SMCReading smc_battery_power = {0};

    if (smc_available) {
        input_power = smc_read_first(
            smc,
            input_power_keys,
            sizeof(input_power_keys) / sizeof(input_power_keys[0]),
            0,
            300
        );
        system_power = smc_read_first(
            smc,
            system_power_keys,
            sizeof(system_power_keys) / sizeof(system_power_keys[0]),
            0,
            300
        );
        smc_battery_power = smc_read_first(
            smc,
            battery_power_keys,
            sizeof(battery_power_keys) / sizeof(battery_power_keys[0]),
            0,
            300
        );
        IOServiceClose(smc);
    }

    /*
     Some SMC battery-current keys expose amperes rather than watts. We only
     accept an SMC battery value when it is reasonably close to the directly
     calculated voltage × current value. Otherwise the public battery reading
     remains authoritative.
    */
    if (smc_battery_power.valid && battery_power_valid) {
        double ratio = smc_battery_power.value / fmax(0.1, battery_power);
        if (ratio < 0.35 || ratio > 2.8) {
            smc_battery_power.valid = false;
        }
    }

    double measured_battery = battery_power_valid
        ? battery_power
        : (smc_battery_power.valid ? smc_battery_power.value : 0);

    bool input_valid = input_power.valid && connected;
    bool system_valid = system_power.valid && connected;

    if (input_valid && !system_valid) {
        double derived = input_power.value - measured_battery;
        if (derived >= 0 && derived <= 200) {
            system_power.valid = true;
            system_power.value = derived;
            strncpy(system_power.key, "DERI", 5);
            strncpy(system_power.type, "calc", 5);
            system_valid = true;
        }
    }

    ensure_output_directory();
    FILE *file = fopen(OUTPUT_TMP, "w");
    if (!file) {
        if (battery) CFRelease(battery);
        return;
    }

    time_t now = time(NULL);
    fprintf(file, "{\n");
    fprintf(file, "  \"schema\": 1,\n");
    fprintf(file, "  \"timestamp\": %lld,\n", (long long)now);
    fprintf(file, "  \"helperVersion\": \"0.5.0\",\n");
    fprintf(file, "  \"smcAvailable\": %s,\n", smc_available ? "true" : "false");
    fprintf(file, "  \"externalConnected\": %s,\n", connected ? "true" : "false");
    fprintf(file, "  \"isCharging\": %s,\n", charging ? "true" : "false");

    if (battery_power_valid || smc_battery_power.valid) {
        fprintf(
            file,
            "  \"batteryPowerWatts\": %.4f,\n",
            measured_battery
        );
        fprintf(
            file,
            "  \"batteryPowerSource\": \"%s\",\n",
            battery_power_valid ? "battery-voltage-current" : "smc"
        );
    } else {
        fprintf(file, "  \"batteryPowerWatts\": null,\n");
        fprintf(file, "  \"batteryPowerSource\": \"unavailable\",\n");
    }

    if (input_valid) {
        fprintf(file, "  \"adapterInputWatts\": %.4f,\n", input_power.value);
        fprintf(file, "  \"adapterInputSource\": ");
        json_string(file, input_power.key);
        fprintf(file, ",\n");
    } else {
        fprintf(file, "  \"adapterInputWatts\": null,\n");
        fprintf(file, "  \"adapterInputSource\": \"unavailable\",\n");
    }

    if (system_valid) {
        fprintf(file, "  \"systemPowerWatts\": %.4f,\n", system_power.value);
        fprintf(file, "  \"systemPowerSource\": ");
        json_string(file, system_power.key);
        fprintf(file, "\n");
    } else {
        fprintf(file, "  \"systemPowerWatts\": null,\n");
        fprintf(file, "  \"systemPowerSource\": \"unavailable\"\n");
    }

    fprintf(file, "}\n");
    fflush(file);
    fsync(fileno(file));
    fclose(file);

    chmod(OUTPUT_TMP, 0644);
    rename(OUTPUT_TMP, OUTPUT_FILE);
    chmod(OUTPUT_FILE, 0644);

    if (battery) CFRelease(battery);
}

int main(void) {
    signal(SIGTERM, stop_handler);
    signal(SIGINT, stop_handler);
    signal(SIGHUP, stop_handler);

    while (running) {
        write_json();
        for (int i = 0; i < SAMPLE_SECONDS * 10 && running; i++) {
            usleep(100000);
        }
    }
    return 0;
}
