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
