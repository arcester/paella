// Minimal AppleSMC float-key reader (same user-client protocol as the open-source SMC tools).
// No privileges needed for reads. Not thread-safe: call from one thread.
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <string.h>
// CHIDPrivate.h is not included: its private HID names clash with IOKitLib.h. Declared there.

typedef struct { unsigned char major, minor, build, reserved; unsigned short release; } SMCVers;
typedef struct { unsigned short version, length; unsigned int cpu, gpu, mem; } SMCPLimit;
typedef struct { unsigned int dataSize, dataType; unsigned char attributes; } SMCKeyInfo;
typedef struct {
    unsigned int key; SMCVers vers; SMCPLimit pLimit; SMCKeyInfo info;
    unsigned char result, status, data8; unsigned int data32; unsigned char bytes[32];
} SMCParam; // 80 bytes, matches the kernel's struct

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCGetKeyInfo = 9 };

static io_connect_t conn;

static unsigned int fourcc(const char *s) { return (unsigned)s[0] << 24 | (unsigned)s[1] << 16 | (unsigned)s[2] << 8 | (unsigned)s[3]; }

static int call(SMCParam *in, SMCParam *out) {
    size_t n = sizeof(SMCParam);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(SMCParam), out, &n) != kIOReturnSuccess || out->result;
}

double ATGSMCReadFloat(const char *key) {
    if (!conn) {
        io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!s) return NAN;
        kern_return_t kr = IOServiceOpen(s, mach_task_self(), 0, &conn);
        IOObjectRelease(s);
        if (kr != KERN_SUCCESS) { conn = 0; return NAN; }
    }
    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    if (call(&in, &out)) return NAN;
    SMCKeyInfo info = out.info;
    if (info.dataType != fourcc("flt ") || info.dataSize != 4) return NAN;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.info.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    if (call(&in, &out)) return NAN;
    float f;
    memcpy(&f, out.bytes, sizeof f);
    return f;
}
