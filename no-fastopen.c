#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>

/* Unbound opens upstream TCP with MSG_FASTOPEN. Some container networks
   accept that call and then drop the handshake, so a DNSKEY that does not
   fit in UDP never arrives. Reporting "not supported" makes Unbound use a
   normal connect instead. Other sendmsg calls are unchanged. */
ssize_t sendmsg(int fd, const struct msghdr *message, int flags) {
    static ssize_t (*real_sendmsg)(int, const struct msghdr *, int);
    if (!real_sendmsg) {
        real_sendmsg = dlsym(RTLD_NEXT, "sendmsg");
    }
    if (flags & MSG_FASTOPEN) {
        errno = EOPNOTSUPP;
        return -1;
    }
    return real_sendmsg(fd, message, flags);
}
