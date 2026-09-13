# berry, vendored

the [berry](https://github.com/berry-lang/berry) script language, embedded in the runtime so the
device can run user scripts. see `VERSION` for the exact upstream commit and `LICENSE` for the mit
terms it arrives under.

vendored rather than fetched: this repository already commits generated output instead of
generating it (`src/scene/zones.zig`), builds do not reach the network, and a language runtime that
shipped the panel a different set of bytes depending on what was in someone's `~` would be a poor
thing to debug at 60 fps.

## what is here

| path | provenance |
|---|---|
| `src/` | upstream `src/`, verbatim, **except that `be_filelib.c` is deleted** |
| `port/berry_conf.h` | ours |
| `port/be_port.c` | ours |
| `port/be_modtab.c` | upstream `default/be_modtab.c`, verbatim; its `#if` guards read our conf |
| `generate/` | committed `coc` output, generated from **our** conf by `tools/gen-berry-const.py` |

## what we changed, and why

**`be_filelib.c` is gone.** it implements the `file()` class, which needs a filesystem this build
does not have. removing it costs four symbols the rest of the tree references unconditionally —
`be_fopen`, `be_fclose` and `be_fread` from `be_exec.c`, and `be_nfunc_open` from `be_baselib.c`,
which always registers the `open()` builtin. `port/be_port.c` supplies those four, and they refuse
rather than pretend: `open()` raises `io_error`, the others return failure.

**`port/berry_conf.h`** starts from upstream's `default/berry_conf.h` and changes only:

| macro | value | why |
|---|---|---|
| `BE_USE_FILE_SYSTEM` | 0 | there is no filesystem for scripts; storage is reached through the api |
| `BE_USE_OS_MODULE` | 0 | it requires the filesystem and would `#error` without it |
| `BE_USE_BYTECODE_SAVER`, `BE_USE_BYTECODE_LOADER` | 0 | nothing here loads or writes bytecode |
| `BE_USE_SHARED_LIB` | 0 | no `dlopen` on this device |
| `BE_USE_DEBUG_MODULE`, `BE_USE_SOLIDIFY_MODULE`, `BE_USE_INTROSPECT_MODULE` | 0 | attack surface for features nothing uses |
| `BE_DEBUG_SOURCE_FILE` | 0 | four bytes per function for a filename there is no file for |
| `BE_VM_OBSERVABILITY_SAMPLING` | 16 | an exponent: 2^16 instructions, about 7.8 ms at the 8.4M instructions/s measured on the device, against 125 ms at upstream's 20. it is how a runaway script gets stopped inside a frame |
| `BE_EXPLICIT_MALLOC`, `BE_EXPLICIT_FREE`, `BE_EXPLICIT_REALLOC` | `tc002_berry_*` | the host owns allocation |

everything else keeps upstream's default, deliberately: `string`, `json`, `math`, `time`, `gc`,
`sys`, `global` and `strict` stay on. trimming further should follow a measurement, not a hunch.

the file also declares the host seam, so every translation unit sees it.

## the seam

berry asks its host for two things, and gets them as extern symbols implemented in
`runtime/src/berry/vm.zig`:

```c
extern void  tc002_berry_write(const char *buffer, size_t length);
extern void *tc002_berry_malloc(size_t size);
extern void  tc002_berry_free(void *ptr);
extern void *tc002_berry_realloc(void *ptr, size_t size);
```

that is the whole interface. the fixture harness collects output into a buffer and allocates from
libc; berryd sends output to the log ring and allocates from a fixed arena. neither arrangement is
visible from in here.

## re-vendoring

```bash
cd runtime
cp ~/git_tree/berry/src/*.c ~/git_tree/berry/src/*.h vendor/berry/src/
rm vendor/berry/src/be_filelib.c
cp ~/git_tree/berry/LICENSE vendor/berry/LICENSE
cp ~/git_tree/berry/default/be_modtab.c vendor/berry/port/be_modtab.c
# re-apply the conf changes above against the new default/berry_conf.h, then:
tools/gen-berry-const.py
zig build test-berry && zig build berry-check
```

update `VERSION`, and check upstream's `default/be_port.c` for entry points that have appeared or
gone: the four stubs exist because the linker asked for them, so the linker is what will tell you
the set has changed.
