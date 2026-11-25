/*
 * Mods app backend: a small bridge between the AppLoad socket and agent.sh.
 *
 * AppLoad starts this as backend/entry with argv[1] = a unix SEQPACKET socket.
 * Each packet pair is { int type; int length; } followed by `length` bytes.
 *
 * Frontend -> backend, type 1:  "<id>\n<verb>\n<arg>\n<arg>..."
 *   runs  /bin/sh <dir>/agent.sh <verb> <arg>...   (no shell parsing of the args)
 * Backend -> frontend, type 2:  "<id>\n<output chunk>"   (stdout + stderr)
 *                      type 3:  "<id>\n<exit code>"
 *
 * Long jobs (install, upgrade, remove) are handed to systemd by agent.sh, so they
 * keep running if the reMarkable UI (and with it this process) restarts.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define MSG_REQUEST 1
#define MSG_OUTPUT 2
#define MSG_DONE 3
#define MSG_TERMINATE -1
#define MAX_MSG (1 << 20)
#define MAX_KIDS 8
#define MAX_ARGS 32

struct header { int type; int length; };
struct kid { pid_t pid; int fd; char id[32]; };

static int sock = -1;
static struct kid kids[MAX_KIDS];
static char agent[PATH_MAX];

static int send_msg(int type, const char *id, const char *data, size_t len) {
	size_t idlen = strlen(id);
	size_t total = idlen + 1 + len;
	char *buf = malloc(total);
	if (!buf) return -1;
	memcpy(buf, id, idlen);
	buf[idlen] = '\n';
	if (len) memcpy(buf + idlen + 1, data, len);
	struct header h = { type, (int)total };
	int ok = send(sock, &h, sizeof h, MSG_NOSIGNAL) == (ssize_t)sizeof h &&
	         send(sock, buf, total, MSG_NOSIGNAL) == (ssize_t)total;
	free(buf);
	return ok ? 0 : -1;
}

static void start(char *msg) {
	char *argv[MAX_ARGS + 4];
	int argc = 0;
	char *id = msg, *p = strchr(msg, '\n');
	if (!p) return;
	*p++ = 0;
	if (strlen(id) >= sizeof kids[0].id) return;
	argv[argc++] = "sh";
	argv[argc++] = agent;
	while (p && argc < MAX_ARGS + 2) {
		char *nl = strchr(p, '\n');
		if (nl) *nl++ = 0;
		argv[argc++] = p;
		p = nl;
	}
	argv[argc] = NULL;

	int slot = -1;
	for (int i = 0; i < MAX_KIDS; i++) if (kids[i].pid == 0) { slot = i; break; }
	if (slot < 0) {
		const char *busy = "busy\n";
		send_msg(MSG_OUTPUT, id, busy, strlen(busy));
		send_msg(MSG_DONE, id, "75", 2);
		return;
	}
	int fds[2];
	if (pipe2(fds, O_CLOEXEC) < 0) { send_msg(MSG_DONE, id, "71", 2); return; }
	pid_t pid = fork();
	if (pid < 0) { close(fds[0]); close(fds[1]); send_msg(MSG_DONE, id, "71", 2); return; }
	if (pid == 0) {
		setsid();
		int devnull = open("/dev/null", O_RDONLY);
		if (devnull >= 0) dup2(devnull, 0);
		dup2(fds[1], 1);
		dup2(fds[1], 2);
		signal(SIGPIPE, SIG_DFL);
		execv("/bin/sh", argv);
		_exit(127);
	}
	close(fds[1]);
	kids[slot].pid = pid;
	kids[slot].fd = fds[0];
	snprintf(kids[slot].id, sizeof kids[slot].id, "%s", id);
}

static void finish(int i) {
	int status = 0;
	waitpid(kids[i].pid, &status, 0);
	int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
	char num[16];
	snprintf(num, sizeof num, "%d", code);
	close(kids[i].fd);
	send_msg(MSG_DONE, kids[i].id, num, strlen(num));
	kids[i].pid = 0;
	kids[i].fd = -1;
}

static void stop_all(void) {
	for (int i = 0; i < MAX_KIDS; i++)
		if (kids[i].pid > 0) kill(-kids[i].pid, SIGTERM);
}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: entry <socket>\n"); return 2; }
	signal(SIGPIPE, SIG_IGN);
	for (int i = 0; i < MAX_KIDS; i++) { kids[i].pid = 0; kids[i].fd = -1; }

	/* agent.sh sits next to this binary */
	char self[PATH_MAX];
	ssize_t n = readlink("/proc/self/exe", self, sizeof self - 1);
	if (n <= 0) { strcpy(self, "backend/entry"); n = strlen(self); }
	self[n] = 0;
	char *slash = strrchr(self, '/');
	if (slash) *slash = 0; else strcpy(self, ".");
	snprintf(agent, sizeof agent, "%s/agent.sh", self);

	sock = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (sock < 0) { perror("socket"); return 1; }
	struct sockaddr_un addr = { 0 };
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof addr.sun_path, "%s", argv[1]);
	if (connect(sock, (struct sockaddr *)&addr, sizeof addr) < 0) { perror("connect"); return 1; }

	char *msg = malloc(MAX_MSG + 1);
	char chunk[8192];
	if (!msg) return 1;
	for (;;) {
		struct pollfd pf[MAX_KIDS + 1];
		int map[MAX_KIDS + 1];
		int np = 0;
		pf[np].fd = sock; pf[np].events = POLLIN; map[np++] = -1;
		for (int i = 0; i < MAX_KIDS; i++)
			if (kids[i].pid > 0) { pf[np].fd = kids[i].fd; pf[np].events = POLLIN; map[np++] = i; }
		if (poll(pf, np, -1) < 0) {
			if (errno == EINTR) continue;
			break;
		}
		if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
			struct header h;
			ssize_t r = recv(sock, &h, sizeof h, 0);
			if (r < (ssize_t)sizeof h) break;
			if (h.length < 0 || h.length > MAX_MSG) break;
			size_t got = 0;
			if (h.length > 0) {
				r = recv(sock, msg, h.length, 0);
				if (r <= 0) break;
				got = r;
			}
			msg[got] = 0;
			if (h.type == MSG_TERMINATE) break;
			if (h.type == MSG_REQUEST) start(msg);
		}
		for (int k = 1; k < np; k++) {
			int i = map[k];
			if (!(pf[k].revents & (POLLIN | POLLHUP | POLLERR))) continue;
			ssize_t r = read(kids[i].fd, chunk, sizeof chunk);
			if (r > 0) {
				if (send_msg(MSG_OUTPUT, kids[i].id, chunk, r) < 0) goto out;
			} else if (r == 0 || errno != EINTR) {
				finish(i);
			}
		}
	}
out:
	stop_all();
	return 0;
}
