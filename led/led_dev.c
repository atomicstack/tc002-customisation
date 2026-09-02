/* linux side of led.h: spidev + sysfs gpio latch. mirrors what libzkgui.so does per frame:
 * GPIO_35 low, 1 ms, write(3072 bytes), 1 ms, GPIO_35 high. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <linux/spi/spidev.h>
#include "led.h"

static void sleep_us(unsigned us) {
    struct timespec ts = { (time_t)(us / 1000000u), (long)(us % 1000000u) * 1000L };
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
}

/* sysfs value files want a fresh write from offset 0 each time */
static int gpio_set(int fd, int level) {
    const char c = level ? '1' : '0';
    if (lseek(fd, 0, SEEK_SET) == -1) return -1;
    return write(fd, &c, 1) == 1 ? 0 : -1;
}

int led_open(led_dev *d, const char *spi_path, const char *gpio_value_path) {
    uint8_t mode = SPI_MODE_0, bits = 8;
    uint32_t hz = LED_SPI_HZ;

    d->spi_fd = -1;
    d->gpio_fd = -1;
    d->pulse_us = LED_PULSE_US;

    int spi = open(spi_path, O_RDWR);
    if (spi < 0) return -1;
    if (ioctl(spi, SPI_IOC_WR_MODE, &mode) < 0 ||
        ioctl(spi, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0 ||
        ioctl(spi, SPI_IOC_WR_MAX_SPEED_HZ, &hz) < 0) {
        int e = errno;
        close(spi);
        errno = e;
        return -1;
    }

    int gpio = open(gpio_value_path, O_WRONLY);
    if (gpio < 0) {
        int e = errno;
        close(spi);
        errno = e;
        return -1;
    }

    d->spi_fd = spi;
    d->gpio_fd = gpio;
    return 0;
}

int led_write(led_dev *d, const uint8_t *frame) {
    if (gpio_set(d->gpio_fd, 0) < 0) return -1;
    sleep_us(d->pulse_us);
    ssize_t n = write(d->spi_fd, frame, LED_FRAME_BYTES);
    int e = errno;
    sleep_us(d->pulse_us);
    gpio_set(d->gpio_fd, 1);   /* always release the latch, even after a failed write */
    if (n < 0) {
        errno = e;
        return -1;
    }
    return (int)n;
}

void led_close(led_dev *d) {
    if (d->spi_fd >= 0) close(d->spi_fd);
    if (d->gpio_fd >= 0) close(d->gpio_fd);
    d->spi_fd = -1;
    d->gpio_fd = -1;
}
