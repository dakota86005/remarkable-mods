/*
 * Sudoku helper for AppLoad: tells the app what the Marker is doing.
 *
 * The tablet hands the Marker to apps as a plain mouse (no eraser end, and no events at all
 * while the tablet's own ink engine is drawing). This program watches the Marker's input
 * device and reports which end is near the screen, where the Marker lands, and the path of
 * each stroke once it lifts. It never grabs the device and never writes to it.
 *
 * Positions are sent as fractions of the digitizer range times 65535, which is how the tablet
 * itself places the pen: screen x = ABS_X / max * width (same for y).
 *
 * AppLoad protocol: argv[1] is a SOCK_SEQPACKET unix socket. A message is an 8 byte header
 * (int32 type, int32 length) followed, when length > 0, by a second packet with the text.
 * If this program exits, AppLoad closes the app, so it only exits when told to.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <linux/input.h>

#define MSG_ERASER 1      /* "1" eraser end in range, "0" not */
#define MSG_STATUS 2      /* text for the app's diagnostics line */
#define MSG_STROKE 3      /* "e;x,y,x,y,..." a finished stroke; e is 1 for the eraser end */
#define MSG_DOWN 4        /* "x,y" the Marker has just touched the screen */
#define MSG_NEAR 5        /* "1" either end of the Marker is within reach of the screen, "0" not */
#define MAX_POINTS 5000
#define SYS_TERMINATE (-1)
#define SYS_NEW_FRONTEND (-2)

static int sock = -1;

static void say(int type, const char *text) {
    int head[2];
    head[0] = type;
    head[1] = (int) strlen(text);
    if (send(sock, head, sizeof head, MSG_NOSIGNAL) < 0) return;
    if (head[1] > 0) send(sock, text, (size_t) head[1], MSG_NOSIGNAL);
}

static int has_bit(const unsigned long *bits, int n) {
    return (int) ((bits[n / (8 * sizeof(long))] >> (n % (8 * sizeof(long)))) & 1UL);
}

/* The Marker's device is the one that reports an eraser tool. */
static int open_marker(char *name, size_t len) {
    char path[64];
    const char *test = getenv("SUDOKU_TEST_DEVICE");     /* for the desk test only */
    if (test) { snprintf(name, len, "test"); return open(test, O_RDONLY | O_NONBLOCK | O_CLOEXEC); }
    for (int i = 0; i < 32; i++) {
        unsigned long keys[(KEY_MAX / (8 * sizeof(long))) + 1];
        snprintf(path, sizeof path, "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        memset(keys, 0, sizeof keys);
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keys), keys) >= 0 && has_bit(keys, BTN_TOOL_RUBBER)) {
            snprintf(name, len, "event%d", i);
            return fd;
        }
        close(fd);
    }
    return -1;
}

static int max_x = 0, max_y = 0;
static int px[MAX_POINTS], py[MAX_POINTS], np = 0;

static void read_ranges(int fd) {
    struct input_absinfo a;
    max_x = max_y = 0;
    if (ioctl(fd, EVIOCGABS(ABS_X), &a) >= 0) max_x = a.maximum;
    if (ioctl(fd, EVIOCGABS(ABS_Y), &a) >= 0) max_y = a.maximum;
    if (getenv("SUDOKU_TEST_DEVICE")) { max_x = 20000; max_y = 30000; }     /* desk test only */
}
static int norm(int v, int max) {
    if (max <= 0) return 0;
    if (v < 0) v = 0;
    if (v > max) v = max;
    return (int) (((long long) v * 65535 + max / 2) / max);
}
static void add_point(int x, int y) {
    if (np > 0) {
        int dx = x - px[np - 1], dy = y - py[np - 1];
        if (dx < 0) dx = -dx;
        if (dy < 0) dy = -dy;
        if (dx + dy < 12) return;          /* under a third of a pixel */
    }
    if (np == MAX_POINTS) {                /* a very long stroke: keep every other point */
        for (int i = 0; i < MAX_POINTS / 2; i++) { px[i] = px[2 * i]; py[i] = py[2 * i]; }
        np = MAX_POINTS / 2;
    }
    px[np] = x; py[np] = y; np++;
}
static void send_stroke(int eraser) {
    static char text[MAX_POINTS * 12 + 16];
    int n = snprintf(text, sizeof text, "%d;", eraser ? 1 : 0);
    for (int i = 0; i < np; i++) n += snprintf(text + n, sizeof text - (size_t) n, i ? ",%d,%d" : "%d,%d", px[i], py[i]);
    say(MSG_STROKE, text);
}

static int key_now(int fd, int code) {
    unsigned long keys[(KEY_MAX / (8 * sizeof(long))) + 1];
    memset(keys, 0, sizeof keys);
    if (ioctl(fd, EVIOCGKEY(sizeof keys), keys) < 0) return 0;
    return has_bit(keys, code);
}
static int rubber_now(int fd) { return key_now(fd, BTN_TOOL_RUBBER); }

int main(int argc, char **argv) {
    struct sockaddr_un addr;
    char name[96] = "";
    int dev = -1, rubber = 0, idle = 0, tip = 0, near = 0;
    int ax = 0, ay = 0, have = 0, touch = 0, was = 0, stroke_rubber = 0;

    signal(SIGPIPE, SIG_IGN);
    if (argc < 2) return 0;
    sock = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (sock < 0) return 0;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, argv[1], sizeof addr.sun_path - 1);
    for (int tries = 0; connect(sock, (struct sockaddr *) &addr, sizeof addr) < 0; tries++) {
        if (tries > 50) return 0;
        usleep(100000);
    }

    for (;;) {
        struct pollfd p[2];
        if (dev < 0 && idle <= 0) {
            dev = open_marker(name, sizeof name);
            if (dev >= 0) {
                char st[96];
                read_ranges(dev); rubber = rubber_now(dev); tip = key_now(dev, BTN_TOOL_PEN); touch = was = 0; np = 0; have = 0;
                near = (tip || rubber) ? 1 : 0;
                snprintf(st, sizeof st, "%s %dx%d", name, max_x, max_y);
                snprintf(name, sizeof name, "%s", st);
                say(MSG_STATUS, name); say(MSG_ERASER, rubber ? "1" : "0"); say(MSG_NEAR, near ? "1" : "0");
            }
            else { say(MSG_STATUS, "no Marker device"); idle = 5; }
        }
        p[0].fd = sock; p[0].events = POLLIN; p[0].revents = 0;
        p[1].fd = dev;  p[1].events = POLLIN; p[1].revents = 0;      /* a negative fd is ignored */
        int n = poll(p, 2, dev < 0 ? 2000 : -1);
        if (n < 0) { if (errno == EINTR) continue; usleep(200000); continue; }
        if (n == 0) { idle--; continue; }

        if (p[0].revents & (POLLHUP | POLLERR | POLLNVAL)) return 0;
        if (p[0].revents & POLLIN) {
            static char body[65536];
            int head[2] = { 0, 0 };
            ssize_t got = recv(sock, head, sizeof head, 0);
            if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            if (got < (ssize_t) sizeof head) return 0;
            if (head[1] > 0 && recv(sock, body, sizeof body, MSG_TRUNC) < 0) return 0;
            if (head[0] == SYS_TERMINATE) return 0;
            if (head[0] == SYS_NEW_FRONTEND) {
                /* The app has just opened: tell it where things stand. */
                np = 0; was = 0;
                say(MSG_STATUS, dev >= 0 ? name : "no Marker device");
                say(MSG_ERASER, rubber ? "1" : "0");
                say(MSG_NEAR, near ? "1" : "0");
            }
        }

        if (dev >= 0 && (p[1].revents & (POLLHUP | POLLERR | POLLNVAL))) {
            close(dev); dev = -1; idle = 1;
            if (rubber) { rubber = 0; say(MSG_ERASER, "0"); }
            tip = 0; if (near) { near = 0; say(MSG_NEAR, "0"); }
            continue;
        }
        if (dev >= 0 && (p[1].revents & POLLIN)) {
            struct input_event ev[64];
            ssize_t got = read(dev, ev, sizeof ev);
            if (got <= 0) {
                if (got < 0 && (errno == EAGAIN || errno == EINTR)) continue;
                close(dev); dev = -1; idle = 1;
                if (rubber) { rubber = 0; say(MSG_ERASER, "0"); }
            tip = 0; if (near) { near = 0; say(MSG_NEAR, "0"); }
                continue;
            }
            for (size_t i = 0; i < (size_t) got / sizeof ev[0]; i++) {
                int type = ev[i].type, code = ev[i].code, value = ev[i].value;
                if (type == EV_ABS) {
                    if (code == ABS_X) { ax = value; have |= 1; }
                    else if (code == ABS_Y) { ay = value; have |= 2; }
                } else if (type == EV_KEY) {
                    if (code == BTN_TOOL_RUBBER) {
                        int now = value ? 1 : 0;
                        if (now != rubber) { rubber = now; say(MSG_ERASER, rubber ? "1" : "0"); }
                    } else if (code == BTN_TOOL_PEN) tip = value ? 1 : 0;
                    else if (code == BTN_TOUCH) touch = value ? 1 : 0;
                } else if (type == EV_SYN && code == SYN_DROPPED) {
                    /* Events were lost: ask the device where things stand. */
                    int now = rubber_now(dev);
                    if (now != rubber) { rubber = now; say(MSG_ERASER, rubber ? "1" : "0"); }
                    /* The stroke so far is still true; whether it goes on is read from the device. */
                    tip = key_now(dev, BTN_TOOL_PEN); touch = key_now(dev, BTN_TOUCH);
                    if (!touch && was) { was = 0; if (np > 0) send_stroke(stroke_rubber); np = 0; }
                    now = (tip || rubber || touch) ? 1 : 0;
                    if (near != now) { near = now; say(MSG_NEAR, near ? "1" : "0"); }
                } else if (type == EV_SYN && code == SYN_REPORT) {
                    int reach = (tip || rubber || touch) ? 1 : 0;
                    if (reach != near) { near = reach; say(MSG_NEAR, near ? "1" : "0"); }
                    if (touch && have == 3) {
                        int x = norm(ax, max_x), y = norm(ay, max_y);
                        if (!was) {
                            char at[32];
                            np = 0; stroke_rubber = rubber; was = 1;
                            snprintf(at, sizeof at, "%d,%d", x, y);
                            say(MSG_DOWN, at);
                        }
                        add_point(x, y);
                    } else if (!touch && was) {
                        was = 0;
                        if (np > 0) send_stroke(stroke_rubber);
                        np = 0;
                    }
                }
            }
        }
    }
}
