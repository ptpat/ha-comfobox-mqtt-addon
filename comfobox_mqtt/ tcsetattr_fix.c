/* 
 * tcsetattr_fix.c — LD_PRELOAD wrapper
 * Fängt tcsetattr() ab und gibt Erfolg zurück wenn ENOTTY auftreten würde.
 * Mono's SerialPort ruft tcsetattr() auf PTY-Slaves auf — PTYs auf ARM/aarch64
 * geben ENOTTY zurück. Dieser Wrapper gibt stattdessen 0 (Erfolg) zurück.
 */
#define _GNU_SOURCE
#include <termios.h>
#include <errno.h>
#include <dlfcn.h>

typedef int (*tcsetattr_fn)(int, int, const struct termios *);

int tcsetattr(int fd, int optional_actions, const struct termios *termios_p) {
    static tcsetattr_fn real_tcsetattr = NULL;
    if (!real_tcsetattr) {
        real_tcsetattr = (tcsetattr_fn)dlsym(RTLD_NEXT, "tcsetattr");
    }
    int result = real_tcsetattr(fd, optional_actions, termios_p);
    if (result == -1 && errno == ENOTTY) {
        /* PTY akzeptiert tcsetattr nicht — ignorieren, Erfolg melden */
        errno = 0;
        return 0;
    }
    return result;
}
