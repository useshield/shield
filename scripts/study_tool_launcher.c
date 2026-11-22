#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

// The child enters its own process group before the external tool starts.
// Limits are hard limits inherited by descendants, including ffmpeg and Deno.
static int limit_resource(int resource, rlim_t value) {
    struct rlimit limit;
    if (getrlimit(resource, &limit) != 0) return -1;
    if (limit.rlim_max != RLIM_INFINITY && value > limit.rlim_max) value = limit.rlim_max;
    limit.rlim_cur = value;
    limit.rlim_max = value;
    return setrlimit(resource, &limit);
}

static volatile sig_atomic_t stopping = 0;
static void stop(int signal_number) { (void)signal_number; stopping = 1; }

int main(int argc, char *argv[]) {
#ifdef SHIELD_CONTAINED_ONLY
    // Release builds start nothing but Apple's sandbox-exec with a profile
    // (StudyContainment), so no tool can run outside the download sandbox.
    if (argc < 4 || strcmp(argv[1], "/usr/bin/sandbox-exec") != 0 || strcmp(argv[2], "-f") != 0) {
        fprintf(stderr, "Study tool launcher runs only sandboxed tools.\n");
        return 125;
    }
#endif
    pid_t owner = getppid();
#ifdef __APPLE__
    // Use the descriptor table capacity, not RLIMIT_NOFILE's hard limit:
    // macOS can report an unlimited hard limit even with a finite table.
    // Capture BEFORE lowering the soft limit to 256, so inherited high FDs
    // are still enumerated. Refuse any untrustworthy capacity.
    int original_fd_table_size = getdtablesize();
    if (original_fd_table_size < 3 || original_fd_table_size > 1048576) {
        fprintf(stderr, "Cannot safely enumerate inherited file descriptors.\n");
        return 125;
    }
#endif
    if (owner <= 1 || argc < 2 || argv[1][0] != '/' || setpgid(0, 0) != 0 ||
        limit_resource(RLIMIT_CPU, 5400) != 0 ||
        limit_resource(RLIMIT_FSIZE, 2500000000ULL) != 0 ||
        limit_resource(RLIMIT_NOFILE, 256) != 0 ||
        limit_resource(RLIMIT_CORE, 0) != 0) {
        fprintf(stderr, "Study tool launcher setup failed: %d\n", errno);
        return 125;
    }
    // A resource limit does not close descriptors already inherited above it.
    // Tools receive only their explicit stdin/stdout/stderr, never an open
    // application file, XPC socket, or authority handle from their parent.
#ifdef __APPLE__
    // closefrom is not declared by the macOS 15 SDK used with Xcode 27.
    // Any failure other than "already closed" aborts before tool launch.
    for (int fd = 3; fd < original_fd_table_size; ++fd) {
        if (close(fd) != 0 && errno != EBADF) {
            fprintf(stderr, "Cannot discard inherited descriptor: %d\n", errno);
            return 125;
        }
    }
#else
    closefrom(3);
#endif
    // Install handlers before fork: cancellation in the short fork/setup
    // window must still reach the supervisor's descendant cleanup path.
    struct sigaction action = {0};
    action.sa_handler = stop;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0 || sigaction(SIGINT, &action, NULL) != 0) return 125;
    // Keep a small supervisor alive when the XPC process dies abruptly. Tools
    // have a separate group, so cleanup can kill that group without killing
    // this supervisor before it has reaped its child and reported its status.
    pid_t child = fork();
    if (child < 0) return 125;
    if (child == 0) {
        if (setpgid(0, 0) != 0) _exit(125);
        execv(argv[1], &argv[1]);
        fprintf(stderr, "Study tool exec failed: %d\n", errno);
        _exit(126);
    }
    (void)setpgid(child, child); // Child also sets it before exec; EACCES is benign.
    int status = 0;
    int reaped = 0;
    while (!stopping && getppid() == owner) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) { reaped = 1; break; }
        if (result < 0 && errno != EINTR) break;
        usleep(50000);
    }
    kill(-child, SIGTERM);
    // Cleanup is shorter than StudyProcessRunner's outer two-second deadline.
    usleep(150000);
    kill(-child, SIGKILL);
    if (!reaped) {
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    if (stopping || getppid() != owner) return 130;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
