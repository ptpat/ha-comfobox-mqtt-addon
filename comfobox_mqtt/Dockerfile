FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        socat \
        unzip \
        tzdata \
        jq \
        mono-complete \
        gcc \
        libc6-dev \
    ; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# LD_PRELOAD Wrapper: tcsetattr() auf PTY gibt ENOTTY auf ARM/aarch64.
# C-Code direkt ins Dockerfile eingebettet — kein separates File nötig.
RUN printf '#define _GNU_SOURCE\n#include <termios.h>\n#include <errno.h>\n#include <dlfcn.h>\ntypedef int (*fn_t)(int,int,const struct termios*);\nint tcsetattr(int fd,int act,const struct termios*t){\n  static fn_t real=NULL;\n  if(!real)real=(fn_t)dlsym(RTLD_NEXT,"tcsetattr");\n  int r=real(fd,act,t);\n  if(r==-1&&errno==ENOTTY){errno=0;return 0;}\n  return r;\n}\n' > /tmp/tcsetattr_fix.c \
    && gcc -shared -fPIC -o /usr/local/lib/tcsetattr_fix.so /tmp/tcsetattr_fix.c -ldl \
    && rm /tmp/tcsetattr_fix.c

WORKDIR /app

COPY . /app

RUN chmod +x /app/run.sh

CMD ["/app/run.sh"]
