/*
 * pmos-dash.c - minimal framebuffer dashboard for postmarketOS (headless phone)
 * Zero graphics library dependency. Double-buffered writes to /dev/fb0.
 * Displays: clock/date, Wi-Fi IP + RSSI, network throughput (RX/TX), TCP
 *           connection state, battery, CPU, top-5 CPU processes, top-5 MEM
 *           processes, memory, temp, disk, uptime.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <ctype.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/statvfs.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <time.h>

/* ---- minimal framebuffer ABI (from linux/fb.h, stable uapi) ---- */
#define FBIOGET_VSCREENINFO 0x4600
#define FBIOGET_FIXSCREENINFO 0x4602
struct fb_bitfield { unsigned int offset; unsigned int length; unsigned int msb_right; };
struct fb_var_screeninfo {
    unsigned int xres, yres, xres_virtual, yres_virtual, xoffset, yoffset;
    unsigned int bits_per_pixel, grayscale;
    struct fb_bitfield red, green, blue, transp;
    unsigned int nonstd, activate, height, width;
    unsigned int accel, pixclock, left_margin, right_margin, upper_margin, lower_margin;
    unsigned int hsync_len, vsync_len, sync, vmode, rotate;
    unsigned int colorspace;
    unsigned int reserved[2];
};
struct fb_fix_screeninfo {
    char id[16];
    unsigned long smem_start;
    unsigned int smem_len, type, type_aux, visual;
    unsigned int xpanstep, ypanstep, ywrapstep, line_length;
    unsigned long mmio_start;
    unsigned int mmio_len, accel;
    unsigned short capabilities;
    unsigned short reserved[3];
};

/* ---------- 5x7 bitmap font (rows joined by '/', '#' = lit pixel) ---------- */
static const char *FONT_ART[] = {
    "...../...../...../...../...../...../.....", /* space */
    ".###./#...#/#..##/#.#.#/##..#/#...#/.###.", /* 0 */
    "..#../.##../..#../..#../..#../..#../.###.", /* 1 */
    ".###./#...#/....#/...#./..#../.#.../#####", /* 2 */
    "####./....#/....#/.###./....#/....#/####.", /* 3 */
    "...#./..##./.#.#./#..#./#####/...#./...#.", /* 4 */
    "#####/#..../#..../####./....#/....#/####.", /* 5 */
    "..##./.#.../#..../####./#...#/#...#/.###.", /* 6 */
    "#####/....#/...#./..#../..#../..#../..#..", /* 7 */
    ".###./#...#/#...#/.###./#...#/#...#/.###.", /* 8 */
    ".###./#...#/#...#/.####/....#/...#./.##..", /* 9 */
    "...../.###./.###./...../.###./.###./.....", /* : */
    "...../...../...../...../...../.##../.##..", /* . */
    "...../...../...../#####/...../...../.....", /* - */
    "....#/....#/...#./..#../.#.../#..../#....", /* / */
    "##..#/##..#/...#./..#../.#.../#..##/#..##", /* % */
    "...../..#../..#../#####/..#../..#../.....", /* + */
    ".###./#...#/#...#/#####/#...#/#...#/#...#", /* A */
    "####./#...#/#...#/####./#...#/#...#/####.", /* B */
    ".###./#...#/#..../#..../#..../#...#/.###.", /* C */
    "####./#...#/#...#/#...#/#...#/#...#/####.", /* D */
    "#####/#..../#..../####./#..../#..../#####", /* E */
    "#####/#..../#..../####./#..../#..../#....", /* F */
    ".###./#...#/#..../#.###/#...#/#...#/.###.", /* G */
    "#...#/#...#/#...#/#####/#...#/#...#/#...#", /* H */
    ".###./..#../..#../..#../..#../..#../.###.", /* I */
    "..###/...#./...#./...#./...#./#..#./.##..", /* J */
    "#...#/#..#./#.#../##.../#.#../#..#./#...#", /* K */
    "#..../#..../#..../#..../#..../#..../#####", /* L */
    "#...#/##.##/#.#.#/#.#.#/#...#/#...#/#...#", /* M */
    "#...#/##..#/#.#.#/#.#.#/#..##/#...#/#...#", /* N */
    ".###./#...#/#...#/#...#/#...#/#...#/.###.", /* O */
    "####./#...#/#...#/####./#..../#..../#....", /* P */
    ".###./#...#/#...#/#...#/#.#.#/#..#./.##.#", /* Q */
    "####./#...#/#...#/####./#.#../#..#./#...#", /* R */
    ".####/#..../#..../.###./....#/....#/####.", /* S */
    "#####/..#../..#../..#../..#../..#../..#..", /* T */
    "#...#/#...#/#...#/#...#/#...#/#...#/.###.", /* U */
    "#...#/#...#/#...#/#...#/#...#/.#.#./..#..", /* V */
    "#...#/#...#/#...#/#.#.#/#.#.#/##.##/#...#", /* W */
    "#...#/#...#/.#.#./..#../.#.#./#...#/#...#", /* X */
    "#...#/#...#/.#.#./..#../..#../..#../..#..", /* Y */
    "#####/....#/...#./..#../.#.../#..../#####", /* Z */
};
static const char *ALPHA = " 0123456789:.-/%+ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/* ---------- framebuffer (double buffered) ---------- */
static int FB_FD;
static struct fb_var_screeninfo VINFO;
static struct fb_fix_screeninfo FINFO;
static unsigned char *FB;   /* mmap'd framebuffer (front) */
static unsigned char *BACK; /* back buffer: draw here, then one memcpy -> FB */
static long FB_SIZE;
static int R_SHIFT, G_SHIFT, B_SHIFT;

static int fb_open(void) {
    FB_FD = open("/dev/fb0", O_RDWR);
    if (FB_FD < 0) { perror("open /dev/fb0"); return -1; }
    if (ioctl(FB_FD, FBIOGET_VSCREENINFO, &VINFO) < 0) { perror("FBIOGET_VSCREENINFO"); return -1; }
    if (ioctl(FB_FD, FBIOGET_FIXSCREENINFO, &FINFO) < 0) { perror("FBIOGET_FIXSCREENINFO"); return -1; }
    R_SHIFT = VINFO.red.offset; G_SHIFT = VINFO.green.offset; B_SHIFT = VINFO.blue.offset;
    FB_SIZE = FINFO.smem_len;
    if (FINFO.line_length == 0 && VINFO.yres > 0)
        FINFO.line_length = FB_SIZE / VINFO.yres;   /* = 2944 on this DRM fb */
    FB = mmap(NULL, FB_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, FB_FD, 0);
    if (FB == MAP_FAILED) { perror("mmap fb"); return -1; }
    BACK = malloc(FB_SIZE);
    if (!BACK) { perror("malloc back buffer"); return -1; }
    memset(BACK, 0, FB_SIZE);
    return 0;
}
static unsigned int color(int r, int g, int b) {
    return ((unsigned int)r << R_SHIFT) | ((unsigned int)g << G_SHIFT) | ((unsigned int)b << B_SHIFT) | (0xFFu << 24);
}
static void px(int x, int y, unsigned int c) {
    if (x < 0 || y < 0 || x >= (int)VINFO.xres || y >= (int)VINFO.yres) return;
    long off = (long)y * FINFO.line_length + (long)x * 4;
    memcpy(BACK + off, &c, 4);   /* BACK only -> no visible partial frame */
}
static void rect(int x, int y, int w, int h, unsigned int c) {
    int x2 = x + w, y2 = y + h;
    for (int yy = y; yy < y2; yy++)
        for (int xx = x; xx < x2; xx++) px(xx, yy, c);
}
static void border(int x, int y, int w, int h, unsigned int c) {
    rect(x, y, w, 1, c); rect(x, y + h - 1, w, 1, c);
    rect(x, y, 1, h, c); rect(x + w - 1, y, 1, h, c);
}
static void text(const char *s, int x, int y, int scale, unsigned int c) {
    int cx = x;
    for (const char *p = s; *p; p++) {
        const char *ap = strchr(ALPHA, *p);
        int gi = ap ? (int)(ap - ALPHA) : 0;
        const char *g = FONT_ART[gi];
        for (int r = 0; r < 7; r++) {
            const char *row = g + r * 6;
            for (int col = 0; col < 5; col++) {
                if (row[col] == '#')
                    rect(cx + col * scale, y + r * scale, scale, scale, c);
            }
        }
        cx += 6 * scale;
    }
}
static int text_w(const char *s, int scale) { return (int)strlen(s) * 6 * scale - scale; }
static void bar(int x, int y, int w, int h, int pct, unsigned int fg) {
    unsigned int track = color(38, 46, 62);
    rect(x, y, w, h, track);
    int fill = w * pct / 100; if (pct > 0 && fill < 2) fill = 2;
    rect(x, y, fill, h, fg);
    border(x, y, w, h, color(70, 82, 104));
}
static void fb_flush(void) {
    /* One whole-frame blit; avoids per-pixel writes to the scanned-out buffer. */
    memcpy(FB, BACK, FB_SIZE);
}

/* ---------- data collectors ---------- */
static int read_int(const char *path) {
    FILE *f = fopen(path, "r"); if (!f) return -1;
    int v = -1; if (fscanf(f, "%d", &v) != 1) v = -1;
    fclose(f); return v;
}
static void get_ip(char *buf, size_t n) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq ifr; memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, "wlan0", IFNAMSIZ - 1);
    if (s >= 0 && ioctl(s, SIOCGIFADDR, &ifr) == 0) {
        struct sockaddr_in *a = (struct sockaddr_in*)&ifr.ifr_addr;
        snprintf(buf, n, "%s", inet_ntoa(a->sin_addr));
    } else snprintf(buf, n, "NO IP");
    if (s >= 0) close(s);
}
static void get_mem(int *pct, long *used_mb, long *total_mb) {
    FILE *f = fopen("/proc/meminfo", "r");
    long total = 0, avail = 0; char line[128];
    if (f) {
        while (fgets(line, sizeof line, f)) {
            if (sscanf(line, "MemTotal: %ld kB", &total) == 1) continue;
            if (sscanf(line, "MemAvailable: %ld kB", &avail) == 1) break;
        }
        fclose(f);
    }
    *total_mb = total / 1024;
    *used_mb = (total - avail) / 1024;
    *pct = total > 0 ? (int)((total - avail) * 100 / total) : 0;
}
/* system-wide CPU jiffies delta over the last sample window; shared by the
 * global CPU gauge and the per-process Top5 so both use the same denominator */
static unsigned long g_sys_delta = 0;
static void get_cpu(int *pct, unsigned long *last_idle, unsigned long *last_total) {
    FILE *f = fopen("/proc/stat", "r"); if (!f) { *pct = 0; g_sys_delta = 0; return; }
    char line[256]; unsigned long u=0,n=0,s=0,i=0;
    if (fgets(line, sizeof line, f)) sscanf(line, "cpu %lu %lu %lu %lu", &u,&n,&s,&i);
    fclose(f);
    unsigned long total = u+n+s+i, idle = i;
    if (*last_total > 0) {
        unsigned long dt = total - *last_total, di = idle - *last_idle;
        g_sys_delta = dt;
        *pct = dt > 0 ? (int)((dt - di) * 100 / dt) : 0;
        if (*pct < 0) *pct = 0; if (*pct > 100) *pct = 100;
    } else { *pct = 0; g_sys_delta = 0; }
    *last_idle = idle; *last_total = total;
}
static int get_temp(void) {
    int maxv = 0;
    for (int z = 0; z < 8; z++) {
        char p[80]; snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone%d/temp", z);
        int t = read_int(p);
        if (t > maxv) maxv = t;
    }
    return maxv / 1000;
}
static int get_batt(void) { return read_int("/sys/class/power_supply/bq27426-0/capacity"); }
static int get_charging(void) {
    FILE *f = fopen("/sys/class/power_supply/bq256xx-charger/online", "r");
    int v = 0; if (f) { fscanf(f, "%d", &v); fclose(f); }
    return v;
}
static void get_disk(int *pct, long *avail_mb) {
    struct statvfs st;
    if (statvfs("/", &st) == 0) {
        double total = (double)st.f_blocks * st.f_frsize;
        double freeb = (double)st.f_bavail * st.f_frsize;
        *pct = (int)((total - freeb) * 100 / total);
        *avail_mb = (long)(freeb / 1048576);
    } else { *pct = 0; *avail_mb = 0; }
}
static void get_uptime(char *buf, size_t n) {
    FILE *f = fopen("/proc/uptime", "r"); double up = 0;
    if (f) { fscanf(f, "%lf", &up); fclose(f); }
    int d = (int)up / 86400, h = ((int)up % 86400) / 3600, m = ((int)up % 3600) / 60;
    if (d > 0) snprintf(buf, n, "%dD %dH %dM", d, h, m);
    else snprintf(buf, n, "%dH %dM", h, m);
}

/* ---- Wi-Fi RSSI: talk directly to wpa_supplicant ctrl socket (no fork) ----
 * wpa_supplicant's ctrl_iface is AF_UNIX/SOCK_DGRAM: the client MUST bind its
 * own local path first, otherwise the reply has no return address and recv()
 * times out. Local socket is bound once and reused across samples.
 */
static int get_rssi(void) {
    static int fd = -1;
    if (fd < 0) {
        fd = socket(AF_UNIX, SOCK_DGRAM, 0);
        if (fd < 0) return -999;
        struct sockaddr_un local;
        memset(&local, 0, sizeof local);
        local.sun_family = AF_UNIX;
        snprintf(local.sun_path, sizeof local.sun_path, "/tmp/pmos-dash-ctrl-%d", (int)getpid());
        unlink(local.sun_path);
        socklen_t llen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(local.sun_path) + 1);
        if (bind(fd, (struct sockaddr*)&local, llen) < 0) { close(fd); fd = -1; return -999; }
        struct sockaddr_un remote;
        memset(&remote, 0, sizeof remote);
        remote.sun_family = AF_UNIX;
        strncpy(remote.sun_path, "/run/wpa_supplicant/wlan0", sizeof remote.sun_path - 1);
        socklen_t rlen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(remote.sun_path) + 1);
        if (connect(fd, (struct sockaddr*)&remote, rlen) < 0) { close(fd); fd = -1; return -999; }
        struct timeval tv = { 1, 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    }
    const char *cmd = "SIGNAL_POLL";
    if (send(fd, cmd, strlen(cmd), 0) < 0) return -999;
    /* drain unsolicited events until we get the SIGNAL_POLL reply */
    for (int attempt = 0; attempt < 4; attempt++) {
        char buf[512];
        int n = (int)recv(fd, buf, sizeof buf - 1, 0);
        if (n <= 0) return -999;
        buf[n] = '\0';
        char *p = strstr(buf, "RSSI=");
        if (p) {
            int rssi = -999;
            if (sscanf(p + 5, "%d", &rssi) == 1) return rssi;
        }
    }
    return -999;
}
static const char *rssi_quality(int r) {
    if (r == -999) return "NO SIGNAL";
    if (r >= -55) return "EXCELLENT";
    if (r >= -65) return "GOOD";
    if (r >= -75) return "FAIR";
    return "WEAK";
}
static int rssi_bars(int r) {
    if (r == -999) return 0;
    if (r >= -55) return 4;
    if (r >= -65) return 3;
    if (r >= -75) return 2;
    return 1;
}

/* ---- network: wlan0 rx/tx bytes, rate over the 2s sample interval ---- */
static void get_net_bytes(unsigned long *rx, unsigned long *tx) {
    *rx = *tx = 0;
    FILE *f = fopen("/proc/net/dev", "r"); if (!f) return;
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *p = strstr(line, "wlan0:");
        if (p) {
            p += 6;
            sscanf(p, "%lu %*u %*u %*u %*u %*u %*u %*u %lu", rx, tx);
            break;
        }
    }
    fclose(f);
}
static void get_net_rate(double *rx_kbps, double *tx_kbps) {
    static unsigned long last_rx = 0, last_tx = 0;
    static int first = 1;
    unsigned long rx = 0, tx = 0;
    get_net_bytes(&rx, &tx);
    if (first || last_rx > rx || last_tx > tx) {
        *rx_kbps = *tx_kbps = 0;
    } else {
        *rx_kbps = (double)(rx - last_rx) / 2.0 / 1024.0;
        *tx_kbps = (double)(tx - last_tx) / 2.0 / 1024.0;
    }
    last_rx = rx; last_tx = tx; first = 0;
}

/* ---- TCP connection counts from /proc/net/tcp{,6} ---- */
static void get_conn(int *estab, int *listen) {
    *estab = *listen = 0;
    const char *paths[2] = { "/proc/net/tcp", "/proc/net/tcp6" };
    for (int k = 0; k < 2; k++) {
        FILE *f = fopen(paths[k], "r"); if (!f) continue;
        char line[256]; int first = 1;
        while (fgets(line, sizeof line, f)) {
            if (first) { first = 0; continue; }
            char st[8];
            if (sscanf(line, "%*s %*s %*s %7s", st) == 1) {
                if (strcmp(st, "01") == 0) (*estab)++;
                else if (strcmp(st, "0A") == 0) (*listen)++;
            }
        }
        fclose(f);
    }
}

/* ---- process name / sampling helpers (shared by CPU and MEM top5) ---- */
#define MAXPROC 256
#define NTOP 5
struct pstat { int pid; unsigned long jif; char name[24]; };
static struct pstat g_prev[MAXPROC];
static int g_prev_n = 0;

static void sanitize_name(const char *src, char *dst, size_t n) {
    size_t j = 0;
    for (const char *p = src; *p && j + 1 < n; p++) {
        char c = *p;
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
        if (strchr(ALPHA, c)) dst[j++] = c; else dst[j++] = '?';
    }
    dst[j] = '\0';
}
/* extract comm from a /proc/[pid]/stat line, uppercase + sanitize */
static void comm_from_stat(const char *line, char *out, size_t n) {
    char *lp = strchr((char*)line, '('), *rp = strrchr((char*)line, ')');
    char tmp[32] = {0};
    if (lp && rp && rp > lp) {
        size_t nl = (size_t)(rp - lp - 1); if (nl > 23) nl = 23;
        memcpy(tmp, lp + 1, nl);
    }
    sanitize_name(tmp, out, n);
}

/* ---- top-5 CPU processes: delta of utime+stime over the sample interval ---- */
static int sample_proc_ticks(struct pstat *arr, int max) {
    DIR *d = opendir("/proc"); if (!d) return 0;
    struct dirent *e; int n = 0;
    while ((e = readdir(d)) && n < max) {
        if (!isdigit((unsigned char)e->d_name[0])) continue;
        int pid = atoi(e->d_name);
        char path[80]; snprintf(path, sizeof path, "/proc/%d/stat", pid);
        FILE *f = fopen(path, "r"); if (!f) continue;
        char line[1024];
        if (fgets(line, sizeof line, f)) {
            char *lp = strchr(line, '('), *rp = strrchr(line, ')');
            if (lp && rp && rp > lp) {
                unsigned long ut = 0, st = 0;
                char *rest = rp + 2; /* field 3 (state) onward */
                /* skip fields 3..13, read utime(14) stime(15) */
                if (sscanf(rest, "%*s %*s %*s %*s %*s %*s %*s %*s %*s %*s %*s %lu %lu", &ut, &st) >= 1) {
                    arr[n].pid = pid;
                    arr[n].jif = ut + st;
                    comm_from_stat(line, arr[n].name, sizeof arr[n].name);
                    n++;
                }
            }
        }
        fclose(f);
    }
    closedir(d);
    return n;
}

struct topitem { char name[24]; int pid; int pct; };
struct rank { unsigned long delta; int idx; };

static void get_top5_cpu(struct topitem *out) {
    static struct pstat cur[MAXPROC];
    static struct rank ranks[MAXPROC];
    int n = sample_proc_ticks(cur, MAXPROC);
    /* Denominator = system-wide jiffies delta (same as the global CPU gauge),
     * NOT the sum of process deltas. Using the sum made the busiest task read
     * ~100% whenever the box was idle (all other deltas ~0), contradicting the
     * 0% global CPU card. With a shared denominator the two agree: when the
     * system is idle every process shows ~0%, and all process percentages add
     * up to roughly the global CPU usage.
     * Note: /proc/stat "cpu" aggregates all 4 cores, so a single core fully
     * busy reads ~25% here (fraction of total system CPU), which is the same
     * convention as top's "%Cpu(s)" summary line. */
    unsigned long denom = g_sys_delta;
    for (int i = 0; i < n; i++) {
        unsigned long last = 0;
        for (int j = 0; j < g_prev_n; j++) if (g_prev[j].pid == cur[i].pid) { last = g_prev[j].jif; break; }
        unsigned long d = (cur[i].jif >= last) ? (cur[i].jif - last) : 0;
        ranks[i].delta = d; ranks[i].idx = i;
    }
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++)
            if (ranks[j].delta > ranks[i].delta) {
                struct rank t = ranks[i]; ranks[i] = ranks[j]; ranks[j] = t;
            }
    for (int k = 0; k < NTOP; k++) {
        if (k < n && denom > 0) {
            struct pstat *ps = &cur[ranks[k].idx];
            int pct = (int)(ranks[k].delta * 100 / denom);
            if (pct > 100) pct = 100;
            snprintf(out[k].name, sizeof out[k].name, "%s", ps->name);
            out[k].pid = ps->pid; out[k].pct = pct;
        } else {
            out[k].name[0] = '\0'; out[k].pid = 0; out[k].pct = 0;
        }
    }
    memcpy(g_prev, cur, sizeof(struct pstat) * (size_t)n);
    g_prev_n = n;
}

/* ---- top-5 MEM processes: RSS (resident pages) from /proc/[pid]/statm ---- */
struct memproc { int pid; long rss_kb; char name[24]; };
struct memitem { char name[24]; int pid; long rss_kb; int pct; };

static int sample_proc_mem(struct memproc *arr, int max) {
    DIR *d = opendir("/proc"); if (!d) return 0;
    struct dirent *e; int n = 0;
    long ps = sysconf(_SC_PAGESIZE); if (ps <= 0) ps = 4096;
    while ((e = readdir(d)) && n < max) {
        if (!isdigit((unsigned char)e->d_name[0])) continue;
        int pid = atoi(e->d_name);
        char path[96];
        /* statm: size resident shared text lib data dt (all in pages) */
        snprintf(path, sizeof path, "/proc/%d/statm", pid);
        FILE *f = fopen(path, "r"); if (!f) continue;
        unsigned long resident = 0;
        if (fscanf(f, "%*lu %lu", &resident) != 1) resident = 0;
        fclose(f);
        if (resident == 0) continue;
        snprintf(path, sizeof path, "/proc/%d/stat", pid);
        f = fopen(path, "r"); if (!f) continue;
        char line[1024];
        if (fgets(line, sizeof line, f)) {
            arr[n].pid = pid;
            arr[n].rss_kb = (long)(resident * (unsigned long)ps / 1024UL);
            comm_from_stat(line, arr[n].name, sizeof arr[n].name);
            n++;
        }
        fclose(f);
    }
    closedir(d);
    return n;
}

static void get_top5_mem(struct memitem *out) {
    static struct memproc cur[MAXPROC];
    int n = sample_proc_mem(cur, MAXPROC);
    /* insertion sort, descending by RSS */
    for (int i = 1; i < n; i++) {
        struct memproc t = cur[i]; int j = i - 1;
        while (j >= 0 && cur[j].rss_kb < t.rss_kb) { cur[j + 1] = cur[j]; j--; }
        cur[j + 1] = t;
    }
    long max = (n > 0) ? cur[0].rss_kb : 1; if (max <= 0) max = 1;
    for (int k = 0; k < NTOP; k++) {
        if (k < n) {
            snprintf(out[k].name, sizeof out[k].name, "%s", cur[k].name);
            out[k].pid = cur[k].pid;
            out[k].rss_kb = cur[k].rss_kb;
            int pct = (int)(cur[k].rss_kb * 100 / max);
            out[k].pct = pct > 100 ? 100 : pct;
        } else {
            out[k].name[0] = '\0'; out[k].pid = 0; out[k].rss_kb = 0; out[k].pct = 0;
        }
    }
}

/* ---------- palette ---------- */
static unsigned int c_bg, c_panel, c_border, c_text, c_muted, c_cyan, c_green, c_amber, c_red, c_blue;
static void palette_init(void) {
    c_bg     = color(10, 14, 22);
    c_panel  = color(20, 27, 40);
    c_border = color(48, 62, 84);
    c_text   = color(232, 238, 248);
    c_muted  = color(140, 156, 180);
    c_cyan   = color(88, 209, 232);
    c_green  = color(110, 231, 168);
    c_amber  = color(245, 200, 106);
    c_red    = color(241, 113, 120);
    c_blue   = color(130, 170, 255);
}

static void card_ex(int x, int y, int w, int h, const char *title, unsigned int tc) {
    rect(x, y, w, h, c_panel);
    border(x, y, w, h, c_border);
    rect(x, y, 4, h, tc);
    text(title, x + 22, y + 8, 2, c_muted);
}
static void card(int y, int h, const char *title, unsigned int tc) {
    card_ex(30, y, 660, h, title, tc);
}

/* draw signal-strength bars in the IP card, right side of RSSI text */
static void signal_bars(int x, int y, int level, unsigned int on) {
    for (int i = 0; i < 4; i++) {
        int bh = 4 + i * 3;
        int by = y + 12 - bh;
        rect(x + i * 9, by, 6, bh, i < level ? on : color(48, 62, 84));
    }
}

static void draw_all(void) {
    char ip[64], up[64], buf[128];
    int memp, cpup, diskp, temp, batt, charging, estab, listen, rssi;
    long used, total, avail;
    static unsigned long last_idle = 0, last_total = 0;
    double rx_kbps = 0, tx_kbps = 0;
    struct topitem tops[NTOP];
    struct memitem mems[NTOP];

    get_ip(ip, sizeof ip);
    rssi = get_rssi();
    get_mem(&memp, &used, &total);
    get_cpu(&cpup, &last_idle, &last_total);
    temp = get_temp(); batt = get_batt(); charging = get_charging();
    get_disk(&diskp, &avail); get_uptime(up, sizeof up);
    get_net_rate(&rx_kbps, &tx_kbps);
    get_conn(&estab, &listen);
    get_top5_cpu(tops);
    get_top5_mem(mems);

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char timebuf[16], datebuf[48], wdays[] = "SUNMONTUEWEDTHUFRISAT";
    snprintf(timebuf, sizeof timebuf, "%02d:%02d", tm->tm_hour, tm->tm_min);
    snprintf(datebuf, sizeof datebuf, "%04d-%02d-%02d  %.*s",
             tm->tm_year+1900, tm->tm_mon+1, tm->tm_mday, 3, wdays + tm->tm_wday*3);

    rect(0, 0, VINFO.xres, VINFO.yres, c_bg);

    /* header */
    text("NOTE5A-SRV", 30, 12, 2, c_cyan);
    text("pmOS  edge", 470, 12, 2, c_muted);

    /* clock + date */
    text(timebuf, 30, 36, 7, c_text);
    text(datebuf, 34, 92, 3, c_blue);
    rect(30, 122, 660, 2, c_border);

    /* IP card + Wi-Fi RSSI */
    card(128, 112, "IP ADDRESS  (WLAN0)", c_cyan);
    snprintf(buf, sizeof buf, "%s", ip);
    text(buf, 52, 156, 5, c_text);
    if (rssi == -999)
        snprintf(buf, sizeof buf, "NO WI-FI SIGNAL");
    else
        snprintf(buf, sizeof buf, "RSSI %d DBM  %s", rssi, rssi_quality(rssi));
    text(buf, 52, 202, 2, rssi >= -65 && rssi != -999 ? c_green : c_amber);
    signal_bars(352, 200, rssi_bars(rssi), c_cyan);
    text("PORT 22 SSH", 450, 202, 2, c_muted);

    /* network throughput card */
    card(248, 130, "NETWORK  WLAN0", c_cyan);
    snprintf(buf, sizeof buf, "RX  %6.1f KB/S", rx_kbps);
    text(buf, 52, 278, 3, c_green);
    snprintf(buf, sizeof buf, "TX  %6.1f KB/S", tx_kbps);
    text(buf, 52, 310, 3, c_blue);
    snprintf(buf, sizeof buf, "TCP  %d ACTIVE / %d LISTEN", estab, listen);
    text(buf, 52, 346, 2, c_muted);

    /* battery card */
    card(386, 92, "BATTERY", c_green);
    snprintf(buf, sizeof buf, "%d%%", batt < 0 ? 0 : batt);
    text(buf, 52, 412, 5, batt >= 0 && batt < 20 ? c_red : c_green);
    if (charging) text("CHG", 330, 416, 2, c_amber);
    bar(52, 452, 616, 16, batt < 0 ? 0 : batt, c_green);

    /* CPU card */
    card(486, 88, "CPU USAGE", c_amber);
    snprintf(buf, sizeof buf, "%d%%", cpup);
    text(buf, 52, 512, 5, c_amber);
    bar(190, 514, 478, 22, cpup, c_amber);

    /* top-5 CPU processes card */
    card(582, 164, "TOP 5 PROCESSES  (CPU 2S)", c_amber);
    for (int i = 0; i < NTOP; i++) {
        int ry = 612 + i * 27;
        snprintf(buf, sizeof buf, "%d", i + 1);
        text(buf, 52, ry, 2, c_muted);
        if (tops[i].name[0]) {
            text(tops[i].name, 82, ry, 2, i == 0 ? c_amber : c_text);
            snprintf(buf, sizeof buf, "%d%%", tops[i].pct);
            text(buf, 470, ry, 2, c_green);
            bar(540, ry + 1, 128, 10, tops[i].pct, i == 0 ? c_amber : c_blue);
        }
    }

    /* top-5 MEM processes card (RSS, bar relative to the largest process) */
    card(754, 164, "TOP 5 PROCESSES  (MEM RSS)", c_blue);
    for (int i = 0; i < NTOP; i++) {
        int ry = 784 + i * 27;
        snprintf(buf, sizeof buf, "%d", i + 1);
        text(buf, 52, ry, 2, c_muted);
        if (mems[i].name[0]) {
            text(mems[i].name, 82, ry, 2, i == 0 ? c_blue : c_text);
            snprintf(buf, sizeof buf, "%ldM", mems[i].rss_kb / 1024);
            text(buf, 450, ry, 2, c_green);
            bar(540, ry + 1, 128, 10, mems[i].pct, i == 0 ? c_blue : c_cyan);
        }
    }

    /* memory card */
    card(926, 84, "MEMORY", c_blue);
    snprintf(buf, sizeof buf, "%ld/%ld MB", used, total);
    text(buf, 52, 952, 4, c_blue);
    bar(52, 986, 616, 16, memp, c_blue);

    /* temperature + disk side by side */
    card_ex(30, 1018, 326, 84, "TEMPERATURE", c_red);
    snprintf(buf, sizeof buf, "%d C", temp);
    text(buf, 48, 1050, 5, temp >= 60 ? c_red : c_green);

    card_ex(364, 1018, 326, 84, "DISK  /", c_amber);
    snprintf(buf, sizeof buf, "%d%% USED", diskp);
    text(buf, 382, 1048, 3, c_amber);
    snprintf(buf, sizeof buf, "%ld MB FREE", avail);
    text(buf, 382, 1076, 2, c_muted);

    /* uptime card */
    card(1110, 72, "UPTIME", c_cyan);
    text(up, 52, 1138, 5, c_text);

    /* footer */
    rect(30, 1190, 660, 2, c_border);
    text("HEADLESS SERVER  /  SHELL VIA SSH", 30, 1200, 2, c_muted);
    text("AUTO WI-FI  CONNECTED", 30, 1224, 2, c_cyan);
}

/* screen on/off state file written by pwrkey-blank daemon.
 * While the backlight is off, skip drawing + full-frame blit to save power.
 * CPU% / rates are relative to the sample window, so after a long off period
 * the first frame on resume still computes correct ratios. */
static int screen_is_on(void) {
    FILE *f = fopen("/run/pwr-screen-state", "r");
    int v = 1;  /* default ON if file missing (e.g. daemon not started) */
    if (f) { if (fscanf(f, "%d", &v) != 1) v = 1; fclose(f); }
    return v != 0;
}

int main(void) {
    if (fb_open() < 0) return 1;
    palette_init();
    while (1) {
        if (screen_is_on()) {
            draw_all();
            fb_flush();
        }
        sleep(2);
    }
    return 0;
}
