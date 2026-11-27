#include "console.h"

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <initializer_list>
#include <poll.h>
#include <termios.h>
#include <unistd.h>

std::atomic<bool> g_quit_requested{false};

// -----------------------------------------------------------------------------
// Terminal state
//
// Kept in plain globals because the fatal-signal handler has to restore it, and
// tcsetattr() is async-signal-safe while almost nothing else is.
// -----------------------------------------------------------------------------
static struct termios g_saved_tio;
static volatile sig_atomic_t g_tio_saved = 0;

static void restore_terminal() {
    if (g_tio_saved) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_saved_tio);
        g_tio_saved = 0;
    }
}

// SIGINT/SIGTERM/SIGHUP ask for an orderly stop, so the run summary is still
// printed. A second one means the simulation thread is not responding: restore
// the terminal and leave at once.
static void on_quit_signal(int sig) {
    if (g_quit_requested.exchange(true)) {
        restore_terminal();
        _exit(128 + sig);
    }
}

// A crash must not leave the terminal raw. Restore it, then let the default
// action (core dump and so on) happen via the reset handler.
static void on_fatal_signal(int sig) {
    restore_terminal();
    raise(sig);
}

static void install_signal_handlers() {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);

    sa.sa_handler = on_quit_signal;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGHUP, &sa, nullptr);

    sa.sa_handler = on_fatal_signal;
    sa.sa_flags = SA_RESETHAND | SA_NODEFER;
    for (int sig : {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT})
        sigaction(sig, &sa, nullptr);

    // A closed stdout (`| head`) should end output, not the process.
    signal(SIGPIPE, SIG_IGN);
}

static void enter_raw_mode() {
    struct termios tio;
    if (tcgetattr(STDIN_FILENO, &tio) != 0) return;
    g_saved_tio = tio;
    g_tio_saved = 1;
    atexit(restore_terminal);

    // Raw input: no line editing, no echo (the guest echoes), and no signal
    // keys, so Ctrl-C reaches the guest shell. Carriage return is left as CR,
    // which is what a serial terminal sends. Output post-processing stays on so
    // a bare-metal program that prints only '\n' still starts a new line.
    tio.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    tio.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    tio.c_cflag |= CS8;
    tio.c_cc[VMIN]  = 1;
    tio.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &tio);
}

// -----------------------------------------------------------------------------

void Console::start(bool read_stdin) {
    if (started_) return;
    started_ = true;

    install_signal_handlers();

    // Both wake-up pipes are non-blocking: a write to a full pipe already
    // guarantees a pending wake-up, so it may fail harmlessly.
    if (pipe2(tx_pipe_, O_NONBLOCK | O_CLOEXEC) != 0 ||
        pipe2(wake_pipe_, O_NONBLOCK | O_CLOEXEC) != 0) {
        perror("fast_sim: pipe");
        exit(255);
    }
    out_thread_ = std::thread(&Console::output_loop, this);

    if (read_stdin) {
        stdin_tty_ = isatty(STDIN_FILENO);
        if (stdin_tty_) {
            enter_raw_mode();
            fprintf(stderr, "fast_sim: console on this terminal, Ctrl-A x to quit\r\n");
        }
        in_thread_ = std::thread(&Console::input_loop, this);
    }
}

void Console::stop() {
    if (!started_) return;
    started_ = false;

    stopping_.store(true, std::memory_order_release);
    const char c = 0;
    (void)!write(wake_pipe_[1], &c, 1);
    wake_output();

    if (in_thread_.joinable()) in_thread_.join();
    if (out_thread_.joinable()) out_thread_.join();
    for (int *p : {wake_pipe_, tx_pipe_})
        for (int i = 0; i < 2; ++i)
            if (p[i] >= 0) { close(p[i]); p[i] = -1; }

    restore_terminal();
}

// -----------------------------------------------------------------------------
// Input thread: stdin -> rx ring.
//
// Waits in poll() on stdin and on a pipe that stop() writes to, so it can be
// woken and joined rather than left blocked in read(). On a TTY it interprets
// the escape: Ctrl-A x quits, Ctrl-A Ctrl-A sends a literal Ctrl-A, and Ctrl-A
// followed by anything else sends that key alone.
// -----------------------------------------------------------------------------
void Console::input_loop() {
    constexpr uint8_t kEscape = 0x01;   // Ctrl-A
    bool escape = false;
    uint8_t buf[256];

    for (;;) {
        struct pollfd fds[2] = {{STDIN_FILENO, POLLIN, 0}, {wake_pipe_[0], POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (fds[1].revents) return;

        if (!(fds[0].revents & (POLLIN | POLLHUP | POLLERR))) continue;
        const ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n <= 0) return;                 // EOF: the guest just sees no more input

        for (ssize_t i = 0; i < n; ++i) {
            uint8_t c = buf[i];
            if (stdin_tty_) {
                if (escape) {
                    escape = false;
                    if (c == 'x' || c == 'X') {
                        g_quit_requested.store(true);
                        return;
                    }
                } else if (c == kEscape) {
                    escape = true;
                    continue;
                }
            }
            // A full ring means the guest is not reading. Wait for it rather
            // than drop keystrokes; this thread is the only one that waits.
            while (!rx_.push(c)) {
                if (stopping_.load(std::memory_order_acquire)) return;
                usleep(1000);
            }
        }
    }
}

// -----------------------------------------------------------------------------
// Output thread: tx ring -> stdout.
//
// Drains the ring in bulk, then announces that it is going to sleep and
// re-checks the ring before blocking in poll() on its wake-up pipe; see
// tx_put() for the other half of that handshake. The poll timeout is only a
// backstop. Draining before checking `stopping_` guarantees every byte the
// guest sent is written before stop() returns.
// -----------------------------------------------------------------------------
void Console::wake_output() {
    const char c = 0;
    (void)!write(tx_pipe_[1], &c, 1);
}

void Console::output_loop() {
    uint8_t buf[4096];
    bool stdout_ok = true;

    for (;;) {
        size_t n;
        while ((n = tx_.pop_bulk(buf, sizeof buf)) > 0) {
            size_t done = 0;
            while (stdout_ok && done < n) {
                const ssize_t w = write(STDOUT_FILENO, buf + done, n - done);
                if (w > 0) done += static_cast<size_t>(w);
                else if (w < 0 && errno == EINTR) continue;
                else stdout_ok = false;     // closed pipe: keep draining, drop the bytes
            }
        }
        if (stopping_.load(std::memory_order_acquire) && tx_.empty())
            return;

        tx_sleeping_.store(true, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_seq_cst);
        if (tx_.empty() && !stopping_.load(std::memory_order_acquire)) {
            struct pollfd pfd = {tx_pipe_[0], POLLIN, 0};
            poll(&pfd, 1, 100);
        }
        tx_sleeping_.store(false, std::memory_order_relaxed);
        char sink[64];
        while (read(tx_pipe_[0], sink, sizeof sink) > 0) {}
    }
}
