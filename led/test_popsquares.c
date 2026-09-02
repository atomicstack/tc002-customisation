/* host tests for popsquares.c: defaults, seeding, decay, re-arm rules, gating, rendering. */
#include <string.h>
#include "check.h"
#include "popsquares.h"

static ps_state st;

static void fill_levels(ps_state *s, float v) {
    for (int i = 0; i < LED_PIXELS; i++) s->level[i] = v;
}

static void test_defaults_match_pixdeck_plugin(void) {
    ps_opts o;
    ps_defaults(&o);
    CHECK_NEAR(o.pop_s, 2.0f, 1e-6);
    CHECK_NEAR(o.alive, 1.0f, 1e-6);
    CHECK_NEAR(o.dim, 0.25f, 1e-6);
    CHECK_EQ(o.dim_lo, 0);
    CHECK_EQ(o.dim_hi, 127);
    CHECK_NEAR(o.tint_frac, 0.15f, 1e-6);
    CHECK_EQ(o.tint[0], 58); CHECK_EQ(o.tint[1], 110); CHECK_EQ(o.tint[2], 165);
}

static void test_init_ranges(void) {
    ps_opts o;
    ps_defaults(&o);
    ps_init(&st, &o, 42);
    int bad_level = 0, bad_rank = 0, tinted = 0;
    for (int i = 0; i < LED_PIXELS; i++) {
        if (st.level[i] < 0.0f || st.level[i] > PS_LEVEL_MAX) bad_level++;
        if (st.rank[i] < 0.0f || st.rank[i] >= 1.0f) bad_rank++;
        tinted += st.tinted[i] ? 1 : 0;
    }
    CHECK_EQ(bad_level, 0);
    CHECK_EQ(bad_rank, 0);
    CHECK(tinted > 60 && tinted < 200);   /* ~15% of 832 = 125 */
}

static void test_init_is_deterministic_per_seed(void) {
    ps_opts o;
    ps_defaults(&o);
    ps_state a, b, c;
    ps_init(&a, &o, 7);
    ps_init(&b, &o, 7);
    ps_init(&c, &o, 8);
    ps_step(&a, &o, 0.02f);
    ps_step(&b, &o, 0.02f);
    CHECK(memcmp(&a, &b, sizeof a) == 0);
    CHECK(memcmp(&a, &c, sizeof a) != 0);
}

static void test_seed_zero_is_not_stuck(void) {
    ps_opts o;
    ps_defaults(&o);
    ps_init(&st, &o, 0);
    int distinct = 0;
    for (int i = 1; i < LED_PIXELS; i++) if (st.level[i] != st.level[0]) distinct++;
    CHECK(distinct > 800);
}

static void test_decay_is_per_second_not_per_frame(void) {
    ps_opts o;
    ps_defaults(&o);
    o.pop_s = 2.0f;
    ps_init(&st, &o, 1);
    fill_levels(&st, 100.0f);
    /* 10 levels' worth of time: pop_s * 10 / 127 seconds */
    ps_step(&st, &o, 2.0f * 10.0f / 127.0f);
    CHECK_NEAR(st.level[0], 90.0f, 1e-3);
    CHECK_NEAR(st.level[831], 90.0f, 1e-3);
    /* the same amount of time at a longer pop drops less */
    o.pop_s = 4.0f;
    fill_levels(&st, 100.0f);
    ps_step(&st, &o, 2.0f * 10.0f / 127.0f);
    CHECK_NEAR(st.level[0], 95.0f, 1e-3);
}

static void test_dt_is_capped(void) {
    ps_opts o;
    ps_defaults(&o);
    o.pop_s = 2.0f;
    ps_init(&st, &o, 1);
    fill_levels(&st, 100.0f);
    ps_step(&st, &o, 100.0f);             /* a long stall */
    CHECK_NEAR(st.level[0], 100.0f - 127.0f * 0.5f / 2.0f, 1e-3);   /* 68.25 */
}

static void test_spent_cell_rearms_to_full(void) {
    ps_opts o;
    ps_defaults(&o);
    o.dim = 0.0f;
    ps_init(&st, &o, 3);
    fill_levels(&st, 0.5f);
    ps_step(&st, &o, o.pop_s / 127.0f);   /* drop of 1 level */
    int full = 0;
    for (int i = 0; i < LED_PIXELS; i++) if (st.level[i] == PS_LEVEL_MAX) full++;
    CHECK_EQ(full, LED_PIXELS);
}

static void test_spent_cell_can_rearm_dim(void) {
    ps_opts o;
    ps_defaults(&o);
    o.dim = 1.0f;
    o.dim_lo = 10;
    o.dim_hi = 20;
    ps_init(&st, &o, 3);
    fill_levels(&st, 0.5f);
    ps_step(&st, &o, o.pop_s / 127.0f);
    int in_range = 0;
    for (int i = 0; i < LED_PIXELS; i++) if (st.level[i] >= 10.0f && st.level[i] <= 20.0f) in_range++;
    CHECK_EQ(in_range, LED_PIXELS);
}

static void test_rearm_redraws_tint_flag(void) {
    ps_opts o;
    ps_defaults(&o);
    ps_init(&st, &o, 5);
    fill_levels(&st, 0.5f);
    o.tint_frac = 1.0f;
    ps_step(&st, &o, o.pop_s / 127.0f);
    int tinted = 0;
    for (int i = 0; i < LED_PIXELS; i++) tinted += st.tinted[i] ? 1 : 0;
    CHECK_EQ(tinted, LED_PIXELS);
    fill_levels(&st, 0.5f);
    o.tint_frac = 0.0f;
    ps_step(&st, &o, o.pop_s / 127.0f);
    tinted = 0;
    for (int i = 0; i < LED_PIXELS; i++) tinted += st.tinted[i] ? 1 : 0;
    CHECK_EQ(tinted, 0);
}

static void test_near_zero_counts_as_spent(void) {
    ps_opts o;
    ps_defaults(&o);
    o.dim = 0.0f;
    ps_init(&st, &o, 3);
    fill_levels(&st, 5e-5f);
    ps_step(&st, &o, 0.0f);               /* no decay at all, but the cell is already spent */
    CHECK_NEAR(st.level[0], PS_LEVEL_MAX, 1e-6);
}

static void test_alive_gates_cells_by_rank(void) {
    ps_opts o;
    ps_defaults(&o);
    ps_init(&st, &o, 9);
    fill_levels(&st, 100.0f);
    o.alive = 0.0f;
    ps_step(&st, &o, 0.001f);
    int zero = 0;
    for (int i = 0; i < LED_PIXELS; i++) if (st.level[i] == 0.0f) zero++;
    CHECK_EQ(zero, LED_PIXELS);

    fill_levels(&st, 100.0f);
    o.alive = 0.5f;
    ps_step(&st, &o, 0.001f);
    zero = 0;
    int consistent = 0;
    for (int i = 0; i < LED_PIXELS; i++) {
        if (st.level[i] == 0.0f) zero++;
        if ((st.rank[i] >= 0.5f) == (st.level[i] == 0.0f)) consistent++;
    }
    CHECK(zero > 300 && zero < 530);      /* about half */
    CHECK_EQ(consistent, LED_PIXELS);
}

static void test_render_colours(void) {
    ps_opts o;
    ps_defaults(&o);
    ps_init(&st, &o, 11);
    uint8_t rgb[LED_PIXELS * 3];

    st.level[0] = 127.0f; st.tinted[0] = 1;   /* full tint */
    st.level[1] = 63.5f;  st.tinted[1] = 0;   /* half white */
    st.level[2] = 0.0f;   st.tinted[2] = 1;   /* dark */
    st.level[3] = 200.0f; st.tinted[3] = 0;   /* over-range clamps */
    st.level[4] = 63.5f;  st.tinted[4] = 1;   /* half tint */
    st.level[5] = -3.0f;  st.tinted[5] = 0;   /* under-range clamps */
    ps_render(&st, &o, rgb);

    CHECK_EQ(rgb[0], 58);  CHECK_EQ(rgb[1], 110); CHECK_EQ(rgb[2], 165);
    CHECK_EQ(rgb[3], 127); CHECK_EQ(rgb[4], 127); CHECK_EQ(rgb[5], 127);
    CHECK_EQ(rgb[6], 0);   CHECK_EQ(rgb[7], 0);   CHECK_EQ(rgb[8], 0);
    CHECK_EQ(rgb[9], 255); CHECK_EQ(rgb[10], 255); CHECK_EQ(rgb[11], 255);
    CHECK_EQ(rgb[12], 29); CHECK_EQ(rgb[13], 55); CHECK_EQ(rgb[14], 82);
    CHECK_EQ(rgb[15], 0);  CHECK_EQ(rgb[16], 0);  CHECK_EQ(rgb[17], 0);
}

static void test_render_uses_row_major_order(void) {
    ps_opts o;
    ps_defaults(&o);
    ps_init(&st, &o, 11);
    fill_levels(&st, 0.0f);
    st.level[1 * LED_W + 2] = 127.0f;     /* x = 2, y = 1 */
    st.tinted[1 * LED_W + 2] = 0;
    uint8_t rgb[LED_PIXELS * 3];
    ps_render(&st, &o, rgb);
    CHECK_EQ(rgb[(1 * LED_W + 2) * 3], 255);
    int lit = 0;
    for (int i = 0; i < LED_PIXELS * 3; i++) if (rgb[i]) lit++;
    CHECK_EQ(lit, 3);
}

int main(void) {
    test_defaults_match_pixdeck_plugin();
    test_init_ranges();
    test_init_is_deterministic_per_seed();
    test_seed_zero_is_not_stuck();
    test_decay_is_per_second_not_per_frame();
    test_dt_is_capped();
    test_spent_cell_rearms_to_full();
    test_spent_cell_can_rearm_dim();
    test_rearm_redraws_tint_flag();
    test_near_zero_counts_as_spent();
    test_alive_gates_cells_by_rank();
    test_render_colours();
    test_render_uses_row_major_order();
    return check_summary("test_popsquares");
}
