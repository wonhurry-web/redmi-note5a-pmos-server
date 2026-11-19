/*
 * pwrkey-blank.c - power-key screen on/off toggle for postmarketOS headless phone
 *
 * Listens on the PMIC power key evdev device, toggles the DSI backlight on a
 * SHORT press (<2s). Long press is ignored (left to the kernel for reboot).
 * State is persisted in /run/pwr-screen-state so other tools can read it.
 *
 * Build:  gcc -O2 -o pwrkey-blank pwrkey-blank.c
 * Run as root (evdev node is root:input).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <linux/input.h>

#define EVDEV_PATH     "/dev/input/event0"        /* pm8941_pwrkey */
#define BL_PATH        "/sys/class/backlight/1a94000.dsi.0/brightness"
#define STATE_PATH     "/run/pwr-screen-state"
#define LONG_PRESS_US  2000000   /* 2s: at or above this, ignore (kernel reboot) */
#define DEBOUNCE_US    80000     /* ignore key-up within 80ms of key-down (noise) */

static volatile sig_atomic_t running = 1;
static void on_sig(int s) { (void)s; running = 0; }

static long now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000000L + ts.tv_nsec / 1000L;
}

static int read_brightness(void) {
    FILE *f = fopen(BL_PATH, "r");
    int v = 255;
    if (f) { if (fscanf(f, "%d", &v) != 1) v = 255; fclose(f); }
    return v;
}

static int write_brightness(int v) {
    FILE *f = fopen(BL_PATH, "w");
    if (!f) return -1;
    fprintf(f, "%d\n", v);
    fclose(f);
    return 0;
}

static void write_state(int on) {
    FILE *f = fopen(STATE_PATH, "w");
    if (f) { fprintf(f, "%d\n", on ? 1 : 0); fclose(f); }
}

static void log_msg(const char *s) {
    /* best-effort to syslog-like file; dashboard/log consumers can read it */
    FILE *f = fopen("/var/log/pwrkey-blank.log", "a");
    if (f) {
        time_t t = time(NULL);
        struct tm *tm = localtime(&t);
        fprintf(f, "[%04d-%02d-%02d %02d:%02d:%02d] %s\n",
                tm->tm_year+1900, tm->tm_mon+1, tm->tm_mday,
                tm->tm_hour, tm->tm_min, tm->tm_sec, s);
        fclose(f);
    }
}

int main(int argc, char **argv) {
    signal(SIGTERM, on_sig);
    signal(SIGINT,  on_sig);
    signal(SIGHUP,  on_sig);

    const char *evpath = (argc > 1) ? argv[1] : EVDEV_PATH;
    int fd = open(evpath, O_RDONLY);
    if (fd < 0) { perror("open evdev"); return 1; }

    /* Consider the screen ON at startup if backlight > 0 */
    int screen_on = read_brightness() > 0;
    write_state(screen_on);
    log_msg(screen_on ? "started: screen ON" : "started: screen OFF");

    struct input_event ev;
    long down_us = 0;
    int key_down = 0;

    while (running) {
        ssize_t n = read(fd, &ev, sizeof ev);
        if (n != (ssize_t)sizeof ev) {
            if (n < 0) { perror("read evdev"); break; }
            continue;
        }
        if (ev.type != EV_KEY || ev.code != KEY_POWER) continue;

        if (ev.value == 1) {                    /* key down */
            if (!key_down) { key_down = 1; down_us = now_us(); }
        } else if (ev.value == 0) {             /* key up */
            if (!key_down) continue;
            key_down = 0;
            long held = now_us() - down_us;
            if (held < DEBOUNCE_US) continue;   /* too short: noise */
            if (held >= LONG_PRESS_US) {
                log_msg("long press ignored (left to kernel)");
                continue;                        /* long press: do not toggle */
            }
            /* Short press -> toggle backlight */
            screen_on = !screen_on;
            if (write_brightness(screen_on ? 255 : 0) == 0) {
                write_state(screen_on);
                log_msg(screen_on ? "short press: screen ON" : "short press: screen OFF");
            } else {
                perror("write brightness");
                screen_on = !screen_on;          /* revert on failure */
            }
        }
        /* ev.value == 2 (autorepeat) intentionally ignored */
    }
    close(fd);
    return 0;
}
