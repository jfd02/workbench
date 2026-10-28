#ifndef TABTERM_PTY_H
#define TABTERM_PTY_H

#include <sys/types.h>

/// Start `path` on a fresh pseudo-terminal, as the leader of a new session with
/// the pty as its controlling terminal.
///
/// This is C rather than Swift because the child side runs between fork() and
/// exec(), where only async-signal-safe calls are allowed — no allocation, no
/// locks, nothing the Swift runtime might do behind our back in a process that
/// has other threads running.
///
/// On success returns 0 and fills in the master side (close-on-exec, and
/// non-blocking) and the child's pid. On failure returns -1 with errno set.
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
);

/// TIOCSWINSZ on the master, which delivers SIGWINCH to the foreground job.
int tabterm_set_size(
    int master,
    unsigned short cols,
    unsigned short rows,
    unsigned short xpixel,
    unsigned short ypixel
);

/// The parent pid of `pid`, or -1 when it can't be read.
pid_t tabterm_parent_pid(pid_t pid);

/// The first child of `pid`, or 0 when it has none.
pid_t tabterm_first_child(pid_t pid);

/// Send SIGHUP to everything a session started: the foreground job, the
/// login process's group, and each of its children's groups — the shell.
///
/// Closing a pty's master only signals the session leader, and the leader here
/// is login(1), which is root-owned and ignores it. So a shell whose terminal
/// went away has to be told directly, or it lingers forever.
/// Async-signal-safe apart from proc_listchildpids, so usable from atexit.
void tabterm_hangup(pid_t leader, int master);

/// Hang up, and keep hanging up every 10 ms until `leader` has exited and been
/// reaped, as Ghostty does. A shell still starting up has SIGHUP ignored (it
/// inherits that from login) until it installs its own handler, so one signal
/// can arrive too early to count. After `timeout_ms`, whatever is left of the
/// session gets SIGKILL. Blocks; returns 1 when the leader was reaped.
int tabterm_hangup_and_reap(pid_t leader, int master, int timeout_ms);

#endif
