/*
 * One boot, four answers.
 *
 * Every userspace attempt so far has ended the same way: the kernel prints
 * "Run <x> as init process" and nothing follows. That message is printed
 * *before* kernel_execve(), so it proves nothing about userspace, and every
 * later diagnostic has depended on the console working - which is the thing in
 * doubt. This program removes that dependency.
 *
 * It reports through /dev/kmsg, which goes to printk and out through
 * uart_console_write(), the polled path that the whole 60-second boot log
 * proves works. A write there needs no inherited file descriptor and no tty.
 *
 * What each line tells us:
 *
 *   PROBE 1 alive          execve worked and user mode runs. If this appears,
 *                          nothing before userspace is broken.
 *   PROBE 2 fd1=<n>        whether the kernel gave init stdio. -1 means
 *                          console_on_rootfs() could not open /dev/console,
 *                          which makes write(1,...) fail with EBADF and every
 *                          ordinary program silent while perfectly healthy.
 *   PROBE 3 tty            written to fd 1. If this reaches the terminal but
 *                          PROBE 2 said fd1 is valid and nothing appeared,
 *                          the tty TX path is the fault.
 *   PROBE 4 fork/wait      process creation and SIGCHLD.
 *
 * Then it execs a shell. If the probes print and the prompt does not, the
 * fault is in the shell binary rather than the machine.
 *
 * Deliberately syscall-only: no printf, no malloc, no locale, no atexit. A
 * libc startup path that hangs would look exactly like a dead core, so this
 * touches as little of it as possible.
 */
#include <fcntl.h>
#include <unistd.h>
#include <sys/wait.h>

static int kmsg = -1;

static unsigned slen(const char *s)
{
    unsigned n = 0;
    while (s[n]) n++;
    return n;
}

/* To kmsg, and also to fd 2, so it appears whichever of the two works. */
static void say(const char *s)
{
    if (kmsg >= 0) write(kmsg, s, slen(s));
    write(2, s, slen(s));
}

static void say_num(int v)
{
    char b[12];
    int i = sizeof(b);
    int neg = v < 0;
    unsigned u = neg ? -(unsigned)v : (unsigned)v;

    b[--i] = '\0';
    do { b[--i] = '0' + (u % 10); u /= 10; } while (u);
    if (neg) b[--i] = '-';
    say(&b[i]);
}

int main(void)
{
    int fd1_ok, status;
    pid_t child;
    char *sh_argv[2];

    /* O_WRONLY only: /dev/kmsg is write-for-injection, read-for-the-ring. */
    kmsg = open("/dev/kmsg", O_WRONLY);

    say("PROBE 1 alive: userspace is executing\n");

    say("PROBE 1b kmsg fd = ");
    say_num(kmsg);
    say("\n");

    /* F_GETFD on fd 1: valid descriptor or EBADF, without writing anything. */
    fd1_ok = fcntl(1, F_GETFD);
    say("PROBE 2 fd1 = ");
    say_num(fd1_ok);
    say(fd1_ok < 0 ? "  (NO STDIO - kernel could not open /dev/console)\n"
                   : "  (stdio present)\n");

    /* The one line that goes only to fd 1. If the terminal shows it, the tty
     * write path works for userspace. */
    if (fd1_ok >= 0)
        write(1, "PROBE 3 tty: this line came from write(1)\n", 41);

    child = fork();
    if (child == 0) {
        _exit(42);
    } else if (child < 0) {
        say("PROBE 4 fork FAILED\n");
    } else {
        wait(&status);
        say(WIFEXITED(status) && WEXITSTATUS(status) == 42
            ? "PROBE 4 fork/wait ok\n"
            : "PROBE 4 fork/wait WRONG STATUS\n");
    }

    say("PROBE 5 exec /bin/sh now\n");

    sh_argv[0] = (char *)"-sh";   /* leading dash: a login shell, reads profile */
    sh_argv[1] = 0;
    execv("/bin/sh", sh_argv);

    /* Only reached if the exec failed, which is itself the answer. */
    say("PROBE 5 exec /bin/sh FAILED - the shell binary is the problem\n");
    for (;;)
        pause();
    return 0;
}
