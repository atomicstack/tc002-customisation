/* the tc002 port: everything berry asks of the outside world.
 *
 * output goes wherever the host sends it -- the log ring in berryd, a buffer in the fixture
 * harness. there is no filesystem: the four entry points below exist only because be_exec.c and
 * be_baselib.c reference them unconditionally, and they refuse rather than pretend. scripts reach
 * storage through the api instead.
 */
#include "berry.h"

BERRY_API void be_writebuffer(const char *buffer, size_t length)
{
    tc002_berry_write(buffer, length);
}

BERRY_API char* be_readstring(char *buffer, size_t size)
{
    (void)buffer; (void)size;
    return NULL; /* no console: berryd has none and the harness never asks */
}

void* be_fopen(const char *filename, const char *modes)
{
    (void)filename; (void)modes;
    return NULL;
}

int be_fclose(void *hfile)
{
    (void)hfile;
    return -1;
}

size_t be_fread(void *hfile, void *buffer, size_t length)
{
    (void)hfile; (void)buffer; (void)length;
    return 0;
}

/* the `open()` builtin, which exists only because be_baselib.c always registers it */
int be_nfunc_open(bvm *vm)
{
    be_raise(vm, "io_error", "this device has no filesystem");
    return 0;
}

/* -- the watchdog --------------------------------------------------------------------------
 *
 * berry calls this hook every 2^BE_VM_OBSERVABILITY_SAMPLING instructions. the decision about
 * whether a script has outstayed its welcome belongs to the host, but the *raise* has to happen
 * here: be_raise longjmps back to the enclosing be_pcall, and a longjmp must not cross a zig
 * frame. so the zig side answers a yes/no question and this file does the jumping.
 *
 * the hook is variadic because berry passes an argument for some events; zig cannot define a
 * variadic function, which is the other reason this shim exists.
 */
extern int tc002_berry_should_stop(void);

static void tc002_obs_hook(bvm *vm, int event, ...)
{
    if (event == BE_OBS_VM_HEARTBEAT && tc002_berry_should_stop()) {
        be_raise(vm, "timeout", "the script ran longer than it is allowed to");
    }
}

void tc002_berry_install_hook(bvm *vm)
{
    be_set_obs_hook(vm, tc002_obs_hook);
}
