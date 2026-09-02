/* popsquares on the tc002 led panel, natively, at a fixed frame rate (60 fps by default).
 *
 * run on the device with the stock app stopped (setprop ctl.stop zkswe) so spidev0.0 and
 * gpio35 are free; tc002-led.sh does that dance from the host. the loop is deadline based:
 * each frame is scheduled at the previous deadline + period, and an overrun resets the
 * deadline instead of bursting to catch up. the simulation advances by measured wall time,
 * so the pop length holds whatever rate is actually achieved. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "led.h"
#include "popsquares.h"

typedef struct {
    int fps;
    int brightness;
    double seconds;     /* 0 = run until signalled */
    uint32_t seed;      /* 0 = from the clock */
    int dry_run;
    int stats;
    ps_opts ps;
} config;

static volatile sig_atomic_t stop_requested = 0;

static void on_signal(int sig) {
    (void)sig;
    stop_requested = 1;
}

static void usage(FILE *out) {
    fputs("usage: popsquares [options]\n"
          "  --fps N          frames per second, 1..240 (60)\n"
          "  --pop S          seconds for a full pop to fade (2)\n"
          "  --alive P        percent of leds that take part, 0..100 (100)\n"
          "  --dim P          percent chance a re-arm comes back dim, 0..100 (25)\n"
          "  --dim-min N      dim re-arm level range, 0..127 (0)\n"
          "  --dim-max N      (127)\n"
          "  --tint-pct P     percent of pops in the tint colour, 0..100 (15)\n"
          "  --tint RRGGBB    tint colour as hex (3a6ea5)\n"
          "  --brightness P   panel brightness, 0..100 (100)\n"
          "  --seconds S      stop after s seconds (run until sigint/sigterm)\n"
          "  --seed N         rng seed (from the clock)\n"
          "  --dry-run        never open spidev/gpio; just run the loop\n"
          "  --stats          print the achieved fps to stderr every 5 s\n"
          "  --help\n", out);
}

static int parse_colour(const char *s, uint8_t out[3]) {
    if (*s == '#') s++;
    if (strlen(s) != 6) return -1;
    char *end;
    unsigned long v = strtoul(s, &end, 16);
    if (*end) return -1;
    out[0] = (uint8_t)(v >> 16);
    out[1] = (uint8_t)(v >> 8);
    out[2] = (uint8_t)v;
    return 0;
}

static int in_range(double v, double lo, double hi, const char *name) {
    if (v < lo || v > hi) {
        fprintf(stderr, "popsquares: %s must be between %g and %g\n", name, lo, hi);
        return 0;
    }
    return 1;
}

static int parse_args(int argc, char **argv, config *c) {
    c->fps = 60;
    c->brightness = 100;
    c->seconds = 0;
    c->seed = 0;
    c->dry_run = 0;
    c->stats = 0;
    ps_defaults(&c->ps);

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--help") || !strcmp(a, "-h")) { usage(stdout); exit(0); }
        if (!strcmp(a, "--dry-run")) { c->dry_run = 1; continue; }
        if (!strcmp(a, "--stats"))   { c->stats = 1; continue; }

        if (i + 1 >= argc) {
            fprintf(stderr, "popsquares: %s needs a value\n", a);
            return -1;
        }
        const char *v = argv[++i];
        double d = atof(v);
        if (!strcmp(a, "--fps"))             { if (!in_range(d, 1, 240, a)) return -1; c->fps = (int)d; }
        else if (!strcmp(a, "--pop"))        { if (!in_range(d, 0.1, 600, a)) return -1; c->ps.pop_s = (float)d; }
        else if (!strcmp(a, "--alive"))      { if (!in_range(d, 0, 100, a)) return -1; c->ps.alive = (float)(d / 100.0); }
        else if (!strcmp(a, "--dim"))        { if (!in_range(d, 0, 100, a)) return -1; c->ps.dim = (float)(d / 100.0); }
        else if (!strcmp(a, "--dim-min"))    { if (!in_range(d, 0, 127, a)) return -1; c->ps.dim_lo = (int)d; }
        else if (!strcmp(a, "--dim-max"))    { if (!in_range(d, 0, 127, a)) return -1; c->ps.dim_hi = (int)d; }
        else if (!strcmp(a, "--tint-pct"))   { if (!in_range(d, 0, 100, a)) return -1; c->ps.tint_frac = (float)(d / 100.0); }
        else if (!strcmp(a, "--brightness")) { if (!in_range(d, 0, 100, a)) return -1; c->brightness = (int)d; }
        else if (!strcmp(a, "--seconds"))    { if (!in_range(d, 0, 1e7, a)) return -1; c->seconds = d; }
        else if (!strcmp(a, "--seed"))       { c->seed = (uint32_t)strtoul(v, NULL, 0); }
        else if (!strcmp(a, "--tint")) {
            if (parse_colour(v, c->ps.tint) < 0) {
                fprintf(stderr, "popsquares: --tint wants RRGGBB hex, got %s\n", v);
                return -1;
            }
        } else {
            fprintf(stderr, "popsquares: unknown option %s\n", a);
            return -1;
        }
    }
    return 0;
}

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* sleep until the absolute monotonic time `deadline`; returns early only on a stop signal */
static void sleep_until(double deadline) {
    for (;;) {
        double remaining = deadline - now_s();
        if (remaining <= 0 || stop_requested) return;
        struct timespec ts = { (time_t)remaining, (long)((remaining - (double)(time_t)remaining) * 1e9) };
        if (nanosleep(&ts, NULL) == 0) return;
        if (errno != EINTR) return;
    }
}

static void install_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

static ps_state state;

int main(int argc, char **argv) {
    config c;
    if (parse_args(argc, argv, &c) < 0) {
        usage(stderr);
        return 2;
    }

    led_dev dev = { -1, -1, LED_PULSE_US };
    if (!c.dry_run && led_open(&dev, LED_SPI_PATH, LED_GPIO_PATH) < 0) {
        fprintf(stderr, "popsquares: cannot open %s / %s: %s (is zkswe stopped?)\n",
                LED_SPI_PATH, LED_GPIO_PATH, strerror(errno));
        return 1;
    }

    install_signals();
    uint32_t seed = c.seed ? c.seed : ((uint32_t)time(NULL) * 2654435761u) ^ (uint32_t)getpid();
    ps_init(&state, &c.ps, seed);

    static uint8_t rgb[LED_PIXELS * 3];
    static uint8_t frame[LED_FRAME_BYTES];
    const double period = 1.0 / c.fps;

    double t0 = now_s(), last = t0, last_stats = t0, deadline = t0;
    long frames = 0, frames_at_stats = 0, short_writes = 0, write_errors = 0;

    while (!stop_requested) {
        double now = now_s();
        if (c.seconds > 0 && now - t0 >= c.seconds) break;

        ps_step(&state, &c.ps, (float)(now - last));
        last = now;
        ps_render(&state, &c.ps, rgb);
        led_pack(rgb, c.brightness, frame);

        if (!c.dry_run) {
            int n = led_write(&dev, frame);
            if (n < 0) write_errors++;
            else if (n != LED_FRAME_BYTES) short_writes++;
        }
        frames++;

        if (c.stats && now - last_stats >= 5.0) {
            fprintf(stderr, "fps=%.1f frames=%ld\n", (double)(frames - frames_at_stats) / (now - last_stats), frames);
            last_stats = now;
            frames_at_stats = frames;
        }

        deadline += period;
        double after = now_s();
        if (deadline < after) deadline = after;   /* overran: skip, do not burst */
        sleep_until(deadline);
    }

    double elapsed = now_s() - t0;

    if (!c.dry_run) {
        /* the panel shows a frame when the next one arrives, so black goes out twice */
        memset(frame, 0, sizeof frame);
        led_write(&dev, frame);
        led_write(&dev, frame);
        led_close(&dev);
    }

    printf("frames=%ld seconds=%.2f fps=%.1f short_writes=%ld write_errors=%ld\n",
           frames, elapsed, elapsed > 0 ? frames / elapsed : 0.0, short_writes, write_errors);
    return 0;
}
