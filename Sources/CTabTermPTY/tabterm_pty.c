#include "tabterm_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int tabterm_spawn(
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *cwd,
    unsigned short cols,
    unsigned short rows,
    unsigned short xpixel,
    unsigned short ypixel,
    int *master_out,
    pid_t *pid_out
) {
    struct winsize size = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = xpixel,
        .ws_ypixel = ypixel,
    };

    int master = -1;
    int slave = -1;
    if (openpty(&master, &slave, NULL, NULL, &size) != 0) {
        return -1;
    }

    // Only the slave belongs in the child.
    fcntl(master, F_SETFD, fcntl(master, F_GETFD) | FD_CLOEXEC);

    // macOS leaves IUTF8 off by default, which makes the line discipline
    // erase half a character on backspace. Ghostty turns it on; so do we.
    struct termios attrs;
    if (tcgetattr(master, &attrs) == 0) {
        attrs.c_iflag |= IUTF8;
        tcsetattr(master, TCSANOW, &attrs);
    }

    // Everything else this process has open must not leak into the shell.
    // Most of it is close-on-exec already, but libraries don't always say so,
    // and the list has to be made before fork: reading it allocates.
    int fd_count = 0;
    int *fds = NULL;
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes > 0) {
        // Headroom for descriptors opened between now and the fork.
        struct proc_fdinfo *info = malloc((size_t)bytes + 64 * sizeof(struct proc_fdinfo));
        if (info) {
            bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, info, bytes + 64 * (int)sizeof(struct proc_fdinfo));
            if (bytes > 0) {
                fd_count = bytes / (int)sizeof(struct proc_fdinfo);
                fds = malloc((size_t)fd_count * sizeof(int));
                if (fds) {
                    for (int i = 0; i < fd_count; i++) fds[i] = info[i].proc_fd;
                } else {
                    fd_count = 0;
                }
            }
            free(info);
        }
    }

    pid_t pid = fork();
    if (pid < 0) {
        int saved = errno;
        free(fds);
        close(master);
        close(slave);
        errno = saved;
        return -1;
    }

    if (pid == 0) {
        // Child. Async-signal-safe calls only from here to exec.

        // Signal dispositions and the mask survive exec; the app may have
        // ignored SIGPIPE, and a shell that inherits that breaks pipelines.
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        for (int sig = 1; sig < NSIG; sig++) {
            sigaction(sig, &action, NULL);
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);

        if (setsid() < 0) _exit(126);
        if (ioctl(slave, TIOCSCTTY, 0) < 0) _exit(126);

        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);
        close(master);
        for (int i = 0; i < fd_count; i++) {
            if (fds[i] > STDERR_FILENO) close(fds[i]);
        }

        if (cwd && cwd[0]) {
            // A directory that has gone away leaves the shell wherever login
            // puts it, which is better than not starting at all.
            chdir(cwd);
        }

        execve(path, argv, envp);
        _exit(127);
    }

    free(fds);
    close(slave);

    int flags = fcntl(master, F_GETFL);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);

    *master_out = master;
    *pid_out = pid;
    return 0;
}

int tabterm_set_size(
    int master,
    unsigned short cols,
    unsigned short rows,
    unsigned short xpixel,
    unsigned short ypixel
) {
    struct winsize size = {
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = xpixel,
        .ws_ypixel = ypixel,
    };
    return ioctl(master, TIOCSWINSZ, &size);
}

pid_t tabterm_parent_pid(pid_t pid) {
    struct kinfo_proc info;
    size_t length = sizeof(info);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0 || length == 0) {
        return -1;
    }
    return info.kp_eproc.e_ppid;
}

void tabterm_hangup(pid_t leader, int master) {
    if (master >= 0) {
        pid_t foreground = tcgetpgrp(master);
        if (foreground > 0) killpg(foreground, SIGHUP);
    }
    if (leader <= 0) return;

    pid_t children[64];
    int bytes = proc_listchildpids(leader, children, (int)sizeof(children));
    int count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    if (count > 64) count = 64;
    for (int i = 0; i < count; i++) {
        if (children[i] <= 0) continue;
        pid_t group = getpgid(children[i]);
        if (group > 0) killpg(group, SIGHUP);
        kill(children[i], SIGHUP);
    }
    killpg(leader, SIGHUP);
}

pid_t tabterm_first_child(pid_t pid) {
    pid_t children[16];
    int bytes = proc_listchildpids(pid, children, (int)sizeof(children));
    int count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    for (int i = 0; i < count && i < 16; i++) {
        if (children[i] > 0) return children[i];
    }
    return 0;
}

static void kill_children(pid_t leader, int sig) {
    pid_t children[64];
    int bytes = proc_listchildpids(leader, children, (int)sizeof(children));
    int count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    for (int i = 0; i < count && i < 64; i++) {
        if (children[i] <= 0) continue;
        pid_t group = getpgid(children[i]);
        if (group > 0 && group != leader) killpg(group, sig);
        kill(children[i], sig);
    }
}

int tabterm_hangup_and_reap(pid_t leader, int master, int timeout_ms) {
    if (leader <= 0) return 1;
    for (int waited = 0; waited <= timeout_ms; waited += 10) {
        tabterm_hangup(leader, master);
        int status = 0;
        pid_t reaped = waitpid(leader, &status, WNOHANG);
        if (reaped == leader || (reaped < 0 && errno == ECHILD)) return 1;
        usleep(10 * 1000);
    }
    // Still here: something is ignoring hangups outright. login itself is
    // root and out of reach, but it exits on its own once its child is gone.
    kill_children(leader, SIGKILL);
    int status = 0;
    for (int waited = 0; waited < 500; waited += 10) {
        pid_t reaped = waitpid(leader, &status, WNOHANG);
        if (reaped == leader || (reaped < 0 && errno == ECHILD)) return 1;
        usleep(10 * 1000);
    }
    return 0;
}
