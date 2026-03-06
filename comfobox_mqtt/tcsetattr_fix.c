/*
 * tcsetattr_fix.c — LD_PRELOAD wrapper für Mono SerialPort auf ARM/aarch64
 *
 * Problem: Mono's SerialPort.Open() ruft intern auf:
 *   1. tcsetattr()     → via TCSETS ioctl
 *   2. ioctl(TIOCMSET) → für DTR/RTS setzen
 *   3. ioctl(TIOCMGET) → für DTR/RTS lesen
 *
 * Auf ARM/aarch64 geben PTY-Slaves ENOTTY zurück für alle diese Aufrufe.
 * Dieser Wrapper fängt ALLE problematischen ioctl-Aufrufe ab.
 */
#define _GNU_SOURCE
#include <stddef.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <errno.h>
#include <dlfcn.h>
#include <stdarg.h>

typedef int (*ioctl_fn)(int, unsigned long, ...);

int ioctl(int fd, unsigned long request, ...) {
    static ioctl_fn real_ioctl = NULL;
    if (!real_ioctl) {
        real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
    }

    va_list args;
    va_start(args, request);
    void *arg = va_arg(args, void *);
    va_end(args);

    int result = real_ioctl(fd, request, arg);

    if (result == -1 && errno == ENOTTY) {
        /*
         * PTY unterstützt dieses ioctl nicht.
         * Betrifft: TCSETS, TCSETSW, TCSETSF (tcsetattr)
         *           TIOCMSET, TIOCMBIS, TIOCMBIC (DTR/RTS)
         *           TIOCMGET (Modem-Status lesen)
         */
        if (request == TIOCMGET && arg != NULL) {
            /* Mono fragt Modem-Bits ab → gib 0 zurück */
            *((int *)arg) = 0;
        }
        errno = 0;
        return 0;
    }
    return result;
}

/* tcsetattr() ist auf Linux ein Wrapper um ioctl(TCSETS),
 * aber zur Sicherheit auch direkt abfangen: */
int tcsetattr(int fd, int optional_actions, const struct termios *termios_p) {
    typedef int (*tcsetattr_fn)(int, int, const struct termios *);
    static tcsetattr_fn real_fn = NULL;
    if (!real_fn) {
        real_fn = (tcsetattr_fn)dlsym(RTLD_NEXT, "tcsetattr");
    }
    int result = real_fn(fd, optional_actions, termios_p);
    if (result == -1 && errno == ENOTTY) {
        errno = 0;
        return 0;
    }
    return result;
}
