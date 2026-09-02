/* pure frame packing for the tc002 led panel; see led.h for the layout. */
#include <string.h>
#include "led.h"

uint8_t led_remap(uint8_t v) {
    if (v == 0) return 0;
    /* libzkgui.so: 50 + (((v-1)*205) >> 1) / 127, the division done as a magic multiply */
    unsigned half = ((unsigned)(v - 1) * 205u) >> 1;
    return (uint8_t)(50 + half / 127);
}

void led_pack(const uint8_t *rgb, int brightness, uint8_t *frame) {
    if (brightness < 0) brightness = 0;
    if (brightness > 100) brightness = 100;

    uint8_t lut[256];
    for (int v = 0; v < 256; v++)
        lut[v] = led_remap((uint8_t)(v * brightness / 100));

    for (int y = 0; y < LED_H; y++) {
        const uint8_t *src = rgb + y * LED_W * 3;
        uint8_t *dst = frame + y * LED_ROW_BYTES;
        for (int i = 0; i < LED_W * 3; i++)
            dst[i] = lut[src[i]];
        memset(dst + LED_W * 3, 0, LED_ROW_BYTES - LED_W * 3);
    }
}
