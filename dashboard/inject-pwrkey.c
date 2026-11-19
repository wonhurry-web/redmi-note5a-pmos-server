/* inject-pwrkey.c - uinput KEY_POWER injector with file-based sync for testing
 *
 * Usage: inject-pwrkey <hold_ms>
 *   1. creates a uinput device named "pwrkey-test", writes /tmp/uinput-ready
 *   2. waits for /tmp/uinput-inject to appear, then sends a KEY_POWER press
 *   3. waits for /tmp/uinput-stop, then destroys the device and exits
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/uinput.h>
#include <linux/input.h>

static void send_key(int fd, int code, int value) {
    struct input_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = EV_KEY; ev.code = code; ev.value = value;
    write(fd, &ev, sizeof ev);
    memset(&ev, 0, sizeof ev);
    ev.type = EV_SYN; ev.code = SYN_REPORT; ev.value = 0;
    write(fd, &ev, sizeof ev);
}
static int exists(const char *p) { return access(p, F_OK) == 0; }

int main(int argc, char **argv) {
    long hold_ms = (argc > 1) ? atol(argv[1]) : 300;
    int fd = open("/dev/uinput", O_WRONLY | O_NDELAY);
    if (fd < 0) { perror("open uinput"); return 1; }
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, KEY_POWER);
    struct uinput_setup us;
    memset(&us, 0, sizeof us);
    us.id.bustype = BUS_VIRTUAL;
    us.id.vendor = 0x1234; us.id.product = 0x5678; us.id.version = 1;
    strncpy(us.name, "pwrkey-test", UINPUT_MAX_NAME_SIZE - 1);
    if (ioctl(fd, UI_DEV_SETUP, &us) < 0) { perror("UI_DEV_SETUP"); return 1; }
    if (ioctl(fd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); return 1; }

    FILE *f = fopen("/tmp/uinput-ready", "w"); if (f) { fputc('1', f); fclose(f); }
    printf("ready, hold=%ldms\n", hold_ms); fflush(stdout);

    while (!exists("/tmp/uinput-inject")) usleep(50000);
    unlink("/tmp/uinput-inject");
    printf("injecting down\n"); fflush(stdout);
    send_key(fd, KEY_POWER, 1);
    usleep(hold_ms * 1000);
    send_key(fd, KEY_POWER, 0);
    printf("injecting up\n"); fflush(stdout);

    while (!exists("/tmp/uinput-stop")) usleep(50000);
    ioctl(fd, UI_DEV_DESTROY);
    close(fd);
    unlink("/tmp/uinput-ready");
    printf("done\n");
    return 0;
}
