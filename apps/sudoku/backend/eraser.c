/*
 * Sudoku helper for AppLoad: tells the app which end of the Marker is near the screen.
 *
 * The tablet hands the Marker to apps as a plain mouse, so the app cannot tell the eraser end
 * from the tip. This program only watches the Marker's own input device for the "eraser in
 * range" key and passes that single bit on. It never grabs the device and never writes to it.
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

static int rubber_now(int fd) {
    unsigned long keys[(KEY_MAX / (8 * sizeof(long))) + 1];
    memset(keys, 0, sizeof keys);
    if (ioctl(fd, EVIOCGKEY(sizeof keys), keys) < 0) return 0;
    return has_bit(keys, BTN_TOOL_RUBBER);
}

int main(int argc, char **argv) {
    struct sockaddr_un addr;
    char name[32] = "";
    int dev = -1, rubber = 0, idle = 0;

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
            if (dev >= 0) { rubber = rubber_now(dev); say(MSG_STATUS, name); say(MSG_ERASER, rubber ? "1" : "0"); }
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
            if (got < (ssize_t) sizeof head) return 0;
            if (head[1] > 0 && recv(sock, body, sizeof body, MSG_TRUNC) < 0) return 0;
            if (head[0] == SYS_TERMINATE) return 0;
            if (head[0] == SYS_NEW_FRONTEND) {
                /* The app has just opened: tell it where things stand. */
                say(MSG_STATUS, dev >= 0 ? name : "no Marker device");
                say(MSG_ERASER, rubber ? "1" : "0");
            }
        }

        if (dev >= 0 && (p[1].revents & (POLLHUP | POLLERR | POLLNVAL))) {
            close(dev); dev = -1; idle = 1;
            if (rubber) { rubber = 0; say(MSG_ERASER, "0"); }
            continue;
        }
        if (dev >= 0 && (p[1].revents & POLLIN)) {
            struct input_event ev[64];
            ssize_t got = read(dev, ev, sizeof ev);
            if (got <= 0) {
                if (got < 0 && (errno == EAGAIN || errno == EINTR)) continue;
                close(dev); dev = -1; idle = 1;
                if (rubber) { rubber = 0; say(MSG_ERASER, "0"); }
                continue;
            }
            int now = rubber;
            for (size_t i = 0; i < (size_t) got / sizeof ev[0]; i++) {
                if (ev[i].type == EV_KEY && ev[i].code == BTN_TOOL_RUBBER) now = ev[i].value ? 1 : 0;
                else if (ev[i].type == EV_SYN && ev[i].code == SYN_DROPPED) now = -1;
            }
            if (now < 0) now = rubber_now(dev);
            if (now != rubber) { rubber = now; say(MSG_ERASER, rubber ? "1" : "0"); }
        }
    }
}
