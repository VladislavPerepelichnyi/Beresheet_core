/*
 * The smallest userspace that proves the machine works.
 *
 * Statically linked and deliberately tiny. Before busybox and a real C library
 * are worth building, the question is narrower: did the kernel unpack the
 * initramfs into a tmpfs, find /init, load an ELF, and enter user mode on a
 * core that has never run user code before? Everything after that is packages.
 *
 * So this writes to fd 1, reads the clock, forks, and waits - which between
 * them exercise the console, the timer, process creation and signals, and
 * report in a form that is unambiguous in a boot log.
 *
 * It must never return: the kernel panics if init exits.
 */
#include <unistd.h>
#include <sys/wait.h>
#include <sys/utsname.h>
#include <time.h>
#include <string.h>

static void say(const char *s) { write(1, s, strlen(s)); }

int main(void)
{
    struct utsname u;
    struct timespec t0, t1;
    pid_t child;
    int status;

    say("\n"
        "================================================================\n"
        " userspace is running on a hand-written RV32IMA core\n"
        "================================================================\n");

    if (uname(&u) == 0) {
        say("  kernel  : "); say(u.sysname);
        say(" ");           say(u.release);
        say("\n  machine : "); say(u.machine);
        say("\n");
    }

    /* The timer, through the SBI, through the CLINT. */
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* fork/exit/wait: process creation and SIGCHLD on this pipeline. */
    child = fork();
    if (child == 0) {
        say("  fork    : child running\n");
        _exit(42);
    } else if (child > 0) {
        wait(&status);
        say(WIFEXITED(status) && WEXITSTATUS(status) == 42
            ? "  wait    : child exited 42, as asked\n"
            : "  wait    : WRONG EXIT STATUS\n");
    } else {
        say("  fork    : FAILED\n");
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    say(t1.tv_sec != t0.tv_sec || t1.tv_nsec != t0.tv_nsec
        ? "  clock   : monotonic time advances\n"
        : "  clock   : TIME IS NOT MOVING\n");

    say("================================================================\n"
        " Linux userspace reached. Idling.\n"
        "================================================================\n");

    for (;;)
        pause();
    return 0;
}
