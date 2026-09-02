/* popsquares simulation: every cell holds a level 0..127 that counts down and snaps back
 * to full (or, now and then, to a random dim level) when spent. a fixed per-cell rank
 * decides whether the cell takes part at all, so lowering the lit fraction removes cells
 * without reshuffling the panel. some pops use the tint colour instead of white.
 *
 * pure: no i/o, no globals, deterministic for a given seed. ported from the pixdeck
 * plugin of the same name, which was ported from the popsquares_tc002 processing sketch. */
#ifndef POPSQUARES_H
#define POPSQUARES_H

#include <stdint.h>
#include "led.h"

#define PS_LEVEL_MAX 127.0f
#define PS_DT_MAX 0.5f   /* longest wall-clock gap credited to one step */
#define PS_SPENT 1e-4f   /* float decay rarely lands on exactly 0; anything this close is spent */

typedef struct {
    float pop_s;      /* seconds for a full pop to fade to nothing */
    float alive;      /* 0..1 fraction of cells that take part */
    float dim;        /* 0..1 chance that a re-arm comes back dim instead of full */
    int dim_lo;       /* dim re-arm level range, 0..127 */
    int dim_hi;
    float tint_frac;  /* 0..1 share of pops that use the tint colour */
    uint8_t tint[3];  /* r, g, b */
} ps_opts;

typedef struct {
    float level[LED_PIXELS];
    float rank[LED_PIXELS];
    uint8_t tinted[LED_PIXELS];
    uint32_t rng;     /* xorshift32 state */
} ps_state;

/* the pixdeck plugin's defaults: pop 2 s, everything alive, 25% dim re-arms over the full
 * range, 15% tinted, tint = steel blue (58, 110, 165). */
void ps_defaults(ps_opts *o);

/* fresh panel: random starting levels so the first frame is already mid-pop, fixed ranks,
 * tinted flags drawn at tint_frac. seed 0 is remapped to a fixed non-zero seed. */
void ps_init(ps_state *s, const ps_opts *o, uint32_t seed);

/* advance every cell by dt seconds of wall time (capped at PS_DT_MAX). */
void ps_step(ps_state *s, const ps_opts *o, float dt);

/* write LED_PIXELS * 3 bytes of row-major r,g,b: white or tint scaled by level / 127. */
void ps_render(const ps_state *s, const ps_opts *o, uint8_t *rgb);

#endif
