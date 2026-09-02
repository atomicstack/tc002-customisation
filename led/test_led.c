/* host tests for led_frame.c: the firmware's level curve and the spi frame layout. */
#include <string.h>
#include "check.h"
#include "led.h"

/* the curve exactly as libzkgui.so computes it: a magic-multiply division by 127 */
static uint8_t firmware_remap(uint8_t v) {
    if (v == 0) return 0;
    uint64_t half = (uint64_t)(((unsigned)(v - 1) * 205u) >> 1);
    return (uint8_t)(50 + ((half * 0x81020409ULL) >> 38));
}

static void test_remap_endpoints(void) {
    CHECK_EQ(led_remap(0), 0);
    CHECK_EQ(led_remap(1), 50);
    CHECK_EQ(led_remap(2), 50);
    CHECK_EQ(led_remap(3), 51);
    CHECK_EQ(led_remap(128), 152);
    CHECK_EQ(led_remap(255), 255);
}

static void test_remap_matches_firmware_for_every_value(void) {
    int mismatches = 0;
    for (int v = 0; v < 256; v++)
        if (led_remap((uint8_t)v) != firmware_remap((uint8_t)v)) mismatches++;
    CHECK_EQ(mismatches, 0);
}

static void set_px(uint8_t *rgb, int x, int y, int r, int g, int b) {
    uint8_t *p = rgb + (y * LED_W + x) * 3;
    p[0] = (uint8_t)r; p[1] = (uint8_t)g; p[2] = (uint8_t)b;
}

static void test_pack_layout(void) {
    uint8_t rgb[LED_PIXELS * 3];
    uint8_t frame[LED_FRAME_BYTES];
    memset(rgb, 0, sizeof rgb);
    set_px(rgb, 0, 0, 1, 2, 3);
    set_px(rgb, LED_W - 1, 0, 255, 0, 0);
    set_px(rgb, 0, LED_H - 1, 0, 255, 0);
    set_px(rgb, LED_W - 1, LED_H - 1, 0, 0, 255);

    led_pack(rgb, 100, frame);

    /* first pixel: remapped r,g,b */
    CHECK_EQ(frame[0], 50); CHECK_EQ(frame[1], 50); CHECK_EQ(frame[2], 51);
    /* last pixel of row 0 sits at byte 153..155 */
    CHECK_EQ(frame[51 * 3], 255); CHECK_EQ(frame[51 * 3 + 1], 0); CHECK_EQ(frame[51 * 3 + 2], 0);
    /* rows are 192 bytes apart */
    CHECK_EQ(frame[15 * LED_ROW_BYTES + 1], 255);
    CHECK_EQ(frame[15 * LED_ROW_BYTES + 51 * 3 + 2], 255);
    /* the 36 padding bytes of every row are zero */
    int pad_nonzero = 0;
    for (int y = 0; y < LED_H; y++)
        for (int i = LED_W * 3; i < LED_ROW_BYTES; i++)
            if (frame[y * LED_ROW_BYTES + i]) pad_nonzero++;
    CHECK_EQ(pad_nonzero, 0);
    /* nothing else lit: 3 + 1 + 1 + 1 nonzero bytes in total */
    int nonzero = 0;
    for (int i = 0; i < LED_FRAME_BYTES; i++) if (frame[i]) nonzero++;
    CHECK_EQ(nonzero, 6);
}

static void test_pack_brightness(void) {
    uint8_t rgb[LED_PIXELS * 3];
    uint8_t frame[LED_FRAME_BYTES];
    memset(rgb, 200, sizeof rgb);

    led_pack(rgb, 50, frame);
    CHECK_EQ(frame[0], 129);          /* 200 * 50 / 100 = 100 -> remap 129 */
    CHECK_EQ(frame[3 * 40 + 2], 129);

    led_pack(rgb, 0, frame);
    int nonzero = 0;
    for (int i = 0; i < LED_FRAME_BYTES; i++) if (frame[i]) nonzero++;
    CHECK_EQ(nonzero, 0);

    led_pack(rgb, 100, frame);
    CHECK_EQ(frame[0], firmware_remap(200));
}

static void test_pack_overwrites_dirty_frame(void) {
    uint8_t rgb[LED_PIXELS * 3];
    uint8_t frame[LED_FRAME_BYTES];
    memset(rgb, 0, sizeof rgb);
    memset(frame, 0xff, sizeof frame);

    led_pack(rgb, 100, frame);
    int nonzero = 0;
    for (int i = 0; i < LED_FRAME_BYTES; i++) if (frame[i]) nonzero++;
    CHECK_EQ(nonzero, 0);
}

int main(void) {
    test_remap_endpoints();
    test_remap_matches_firmware_for_every_value();
    test_pack_layout();
    test_pack_brightness();
    test_pack_overwrites_dirty_frame();
    return check_summary("test_led");
}
