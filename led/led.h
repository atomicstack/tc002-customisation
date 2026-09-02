/* tc002 led panel over raw spi: frame packing (pure) and device i/o (linux).
 *
 * the stock firmware (zkgui) drives the 52x16 panel by writing 3072-byte frames to
 * /dev/spidev0.0 at 10 mhz, mode 0, with a latch pulse on GPIO_35 around each write.
 * a frame is 16 rows of 192 bytes: 52 pixels x 3 bytes (r,g,b) followed by 36 zero
 * bytes. the panel displays a frame when the *next* pulsed frame arrives, so a final
 * image has to be written twice. */
#ifndef TC002_LED_H
#define TC002_LED_H

#include <stddef.h>
#include <stdint.h>

#define LED_W 52
#define LED_H 16
#define LED_PIXELS (LED_W * LED_H)              /* 832 */
#define LED_ROW_BYTES 192                       /* 52 px * 3 + 36 zero bytes */
#define LED_FRAME_BYTES (LED_H * LED_ROW_BYTES) /* 3072 */

#define LED_SPI_PATH "/dev/spidev0.0"
#define LED_GPIO_PATH "/sys/class/gpio/gpio35/value"
#define LED_SPI_HZ 10000000
#define LED_PULSE_US 1000

/* the firmware's level curve: 0 stays 0, 1..255 land on 50..255 (an led-driver floor). */
uint8_t led_remap(uint8_t v);

/* pack a row-major rgb888 image (LED_PIXELS * 3 bytes) into a LED_FRAME_BYTES spi frame,
 * scaling every byte by brightness (0..100) and then applying led_remap(). every byte of
 * the frame is written, including the row padding. */
void led_pack(const uint8_t *rgb, int brightness, uint8_t *frame);

typedef struct {
    int spi_fd;
    int gpio_fd;
    unsigned pulse_us; /* delay after latch-low and after the write, before latch-high */
} led_dev;

/* open spidev (mode 0, 8 bits, LED_SPI_HZ) and the gpio value file. 0 on success,
 * -1 with errno set (nothing left open). */
int led_open(led_dev *d, const char *spi_path, const char *gpio_value_path);

/* latch low, wait, write one LED_FRAME_BYTES frame, wait, latch high.
 * returns the number of bytes written, or -1 with errno set. */
int led_write(led_dev *d, const uint8_t *frame);

void led_close(led_dev *d);

#endif
