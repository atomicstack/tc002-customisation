/* popsquares simulation; see popsquares.h. */
#include "popsquares.h"

static uint32_t xorshift32(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return *s = x;
}

/* uniform in [0, 1) with 24 bits of resolution */
static float unit(uint32_t *s) {
    return (float)(xorshift32(s) >> 8) * (1.0f / 16777216.0f);
}

static float uniform(uint32_t *s, float lo, float hi) {
    return lo + (hi - lo) * unit(s);
}

void ps_defaults(ps_opts *o) {
    o->pop_s = 2.0f;
    o->alive = 1.0f;
    o->dim = 0.25f;
    o->dim_lo = 0;
    o->dim_hi = 127;
    o->tint_frac = 0.15f;
    o->tint[0] = 58;
    o->tint[1] = 110;
    o->tint[2] = 165;
}

void ps_init(ps_state *s, const ps_opts *o, uint32_t seed) {
    s->rng = seed ? seed : 0x9e3779b9u;
    for (int i = 0; i < LED_PIXELS; i++) {
        s->level[i] = uniform(&s->rng, 0.0f, PS_LEVEL_MAX);
        s->rank[i] = unit(&s->rng);
        s->tinted[i] = unit(&s->rng) < o->tint_frac;
    }
}

/* a spent cell usually snaps back to full; sometimes it comes back dim, which is the twinkle */
static void rearm(ps_state *s, int i, const ps_opts *o) {
    int lo = o->dim_lo < o->dim_hi ? o->dim_lo : o->dim_hi;
    int hi = o->dim_lo < o->dim_hi ? o->dim_hi : o->dim_lo;
    s->level[i] = unit(&s->rng) < o->dim ? uniform(&s->rng, (float)lo, (float)hi) : PS_LEVEL_MAX;
    s->tinted[i] = unit(&s->rng) < o->tint_frac;
}

void ps_step(ps_state *s, const ps_opts *o, float dt) {
    if (dt < 0.0f) dt = 0.0f;
    if (dt > PS_DT_MAX) dt = PS_DT_MAX;
    float pop = o->pop_s > 0.0f ? o->pop_s : 1.0f;
    float drop = PS_LEVEL_MAX * dt / pop;   /* a full pop lasts pop_s seconds at any frame rate */

    for (int i = 0; i < LED_PIXELS; i++) {
        if (s->rank[i] >= o->alive) {
            s->level[i] = 0.0f;             /* this led sits the animation out */
            continue;
        }
        s->level[i] -= drop;
        if (s->level[i] <= PS_SPENT)
            rearm(s, i, o);
    }
}

void ps_render(const ps_state *s, const ps_opts *o, uint8_t *rgb) {
    static const uint8_t white[3] = {255, 255, 255};
    for (int i = 0; i < LED_PIXELS; i++) {
        float f = s->level[i] / PS_LEVEL_MAX;
        if (f < 0.0f) f = 0.0f;
        if (f > 1.0f) f = 1.0f;
        const uint8_t *c = s->tinted[i] ? o->tint : white;
        rgb[i * 3 + 0] = (uint8_t)(c[0] * f);
        rgb[i * 3 + 1] = (uint8_t)(c[1] * f);
        rgb[i * 3 + 2] = (uint8_t)(c[2] * f);
    }
}
