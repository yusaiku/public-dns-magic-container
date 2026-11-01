/* Count response bytes by country. The client address is used for one
 * lookup and then discarded. Nothing written to disk contains an address. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <maxminddb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define MAX_COUNTRIES 64
#define MAX_MSG 512

struct country {
    char code[3];
    uint64_t bytes;
};

static struct country countries[MAX_COUNTRIES];
static size_t country_count;
static uint64_t other_bytes;
static MMDB_s mmdb;
static int mmdb_open;
static time_t db_mtime;
static int db_fail_logged;
static volatile sig_atomic_t stop_flag;
static const char *sock_path;
static const char *db_path;
static const char *out_path;

static void on_stop(int sig) {
    (void)sig;
    stop_flag = 1;
}

static const char *pick_path(const char *env, const char *fallback) {
    const char *value = getenv(env);
    if (value == NULL || value[0] == '\0' || strlen(value) > 200) {
        return fallback;
    }
    return value;
}

static void mkdir_one(const char *path) {
    if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "country counter could not create a directory\n");
    }
}

static void mkdir_parent(const char *file) {
    char buf[256];
    char *slash;
    if (strlen(file) >= sizeof buf) {
        return;
    }
    memcpy(buf, file, strlen(file) + 1);
    slash = strrchr(buf, '/');
    if (slash == NULL || slash == buf) {
        return;
    }
    *slash = '\0';
    mkdir_one(buf);
}

static int token_is_ip(const char *token, size_t length, char *out, size_t out_len) {
    unsigned char raw[16];
    if (length == 0 || length >= out_len) {
        return 0;
    }
    memcpy(out, token, length);
    out[length] = '\0';
    if (inet_pton(AF_INET, out, raw) == 1) {
        return AF_INET;
    }
    if (inet_pton(AF_INET6, out, raw) == 1) {
        return AF_INET6;
    }
    return 0;
}

static int token_is_bytes(const char *token, size_t length, unsigned long long *out) {
    unsigned long long value = 0;
    size_t i;
    if (length == 0 || length > 16) {
        return 0;
    }
    for (i = 0; i < length; i++) {
        if (token[i] < '0' || token[i] > '9') {
            return 0;
        }
        value = value * 10u + (unsigned)(token[i] - '0');
    }
    /* A single connection or response above 1 TB is not a DNS answer. */
    if (value == 0 || value > 1000000000000ULL) {
        return 0;
    }
    *out = value;
    return 1;
}

static int skip_address(int family, const unsigned char *raw) {
    if (family == AF_INET) {
        if (raw[0] == 0 || raw[0] == 10 || raw[0] == 127 || raw[0] >= 224) {
            return 1;
        }
        if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) {
            return 1;
        }
        if (raw[0] == 192 && raw[1] == 168) {
            return 1;
        }
        if (raw[0] == 169 && raw[1] == 254) {
            return 1;
        }
        if (raw[0] == 192 && raw[1] == 0 && raw[2] == 2) {
            return 1;
        }
        if (raw[0] == 198 && raw[1] == 51 && raw[2] == 100) {
            return 1;
        }
        if (raw[0] == 203 && raw[1] == 0 && raw[2] == 113) {
            return 1;
        }
        return 0;
    }
    if (raw[0] == 0xff) {
        return 1;
    }
    if ((raw[0] & 0xfe) == 0xfc) {
        return 1;
    }
    if (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80) {
        return 1;
    }
    for (int i = 0; i < 16; i++) {
        if (raw[i] != 0 && !(i == 15 && raw[i] == 1)) {
            return 0;
        }
    }
    return 1;
}

static void add_bytes(const char *code, unsigned long long bytes) {
    size_t i;
    if (code == NULL) {
        other_bytes += bytes;
        return;
    }
    for (i = 0; i < country_count; i++) {
        if (strcmp(countries[i].code, code) == 0) {
            countries[i].bytes += bytes;
            return;
        }
    }
    if (country_count >= MAX_COUNTRIES) {
        other_bytes += bytes;
        return;
    }
    memcpy(countries[country_count].code, code, 3);
    countries[country_count].bytes = bytes;
    country_count++;
}

static void maybe_reload(void) {
    struct stat st;
    int rc;
    if (stat(db_path, &st) != 0) {
        if (mmdb_open) {
            MMDB_close(&mmdb);
            mmdb_open = 0;
        }
        if (!db_fail_logged) {
            fprintf(stderr, "country database missing\n");
            db_fail_logged = 1;
        }
        return;
    }
    if (mmdb_open && st.st_mtime == db_mtime) {
        return;
    }
    if (mmdb_open) {
        MMDB_close(&mmdb);
        mmdb_open = 0;
    }
    rc = MMDB_open(db_path, MMDB_MODE_MMAP, &mmdb);
    if (rc != MMDB_SUCCESS) {
        if (!db_fail_logged) {
            fprintf(stderr, "country database could not be opened\n");
            db_fail_logged = 1;
        }
        return;
    }
    mmdb_open = 1;
    db_mtime = st.st_mtime;
    db_fail_logged = 0;
    fprintf(stderr, "country database loaded\n");
}

static int country_code(int family, const unsigned char *raw, char out[3]) {
    struct sockaddr_storage storage;
    int mmdb_error = 0;
    MMDB_lookup_result_s result;
    MMDB_entry_data_s data;
    const char *paths[2][3] = {
        {"country", "iso_code", NULL},
        {"registered_country", "iso_code", NULL},
    };
    memset(&storage, 0, sizeof storage);
    if (family == AF_INET) {
        struct sockaddr_in *addr = (struct sockaddr_in *)&storage;
        addr->sin_family = AF_INET;
        memcpy(&addr->sin_addr, raw, 4);
    } else {
        struct sockaddr_in6 *addr = (struct sockaddr_in6 *)&storage;
        addr->sin6_family = AF_INET6;
        memcpy(&addr->sin6_addr, raw, 16);
    }
    if (!mmdb_open) {
        return 0;
    }
    result = MMDB_lookup_sockaddr(&mmdb, (struct sockaddr *)&storage, &mmdb_error);
    if (mmdb_error != MMDB_SUCCESS || !result.found_entry) {
        return 0;
    }
    for (int i = 0; i < 2; i++) {
        int status = MMDB_get_value(&result.entry, &data, paths[i][0], paths[i][1], paths[i][2]);
        if (status != MMDB_SUCCESS || !data.has_data || data.type != MMDB_DATA_TYPE_UTF8_STRING) {
            continue;
        }
        if (data.data_size != 2 || !isupper((unsigned char)data.utf8_string[0]) || !isupper((unsigned char)data.utf8_string[1])) {
            continue;
        }
        out[0] = data.utf8_string[0];
        out[1] = data.utf8_string[1];
        out[2] = '\0';
        return 1;
    }
    return 0;
}

static void observe(const char *ip, unsigned long long bytes) {
    unsigned char raw[16];
    unsigned char mapped[4];
    char code[3];
    int family = 0;
    if (inet_pton(AF_INET, ip, raw) == 1) {
        family = AF_INET;
    } else if (inet_pton(AF_INET6, ip, raw) == 1) {
        family = AF_INET6;
        if (raw[0] == 0 && raw[1] == 0 && raw[2] == 0 && raw[3] == 0 && raw[4] == 0 && raw[5] == 0 && raw[6] == 0 && raw[7] == 0 && raw[8] == 0 && raw[9] == 0 && raw[10] == 0xff && raw[11] == 0xff) {
            memcpy(mapped, raw + 12, 4);
            memcpy(raw, mapped, 4);
            family = AF_INET;
        }
    } else {
        return;
    }
    if (skip_address(family, raw)) {
        return;
    }
    if (!country_code(family, raw, code)) {
        return;
    }
    add_bytes(code, bytes);
}

static void handle_message(char *buf, size_t length) {
    char ip[64];
    int have_ip = 0;
    int have_bytes = 0;
    unsigned long long bytes = 0;
    size_t i = 0;
    ip[0] = '\0';
    while (i < length) {
        char token_ip[64];
        size_t start;
        size_t token_len;
        int family;
        while (i < length && (buf[i] == ' ' || buf[i] == '\t' || buf[i] == '\n' || buf[i] == '\r')) {
            i++;
        }
        start = i;
        while (i < length && buf[i] != ' ' && buf[i] != '\t' && buf[i] != '\n' && buf[i] != '\r') {
            i++;
        }
        token_len = i - start;
        if (token_len == 0) {
            break;
        }
        family = token_is_ip(buf + start, token_len, token_ip, sizeof token_ip);
        if (family != 0) {
            memcpy(ip, token_ip, sizeof ip);
            have_ip = 1;
            have_bytes = 0;
            continue;
        }
        if (have_ip && token_is_bytes(buf + start, token_len, &bytes)) {
            have_bytes = 1;
        }
    }
    if (have_ip && have_bytes) {
        observe(ip, bytes);
    }
}

static void write_totals(void) {
    char tmp[256];
    FILE *file;
    size_t i;
    int first = 1;
    if (strlen(out_path) + 5 >= sizeof tmp) {
        return;
    }
    snprintf(tmp, sizeof tmp, "%s.tmp", out_path);
    file = fopen(tmp, "w");
    if (file == NULL) {
        return;
    }
    fputc('{', file);
    for (i = 0; i < country_count; i++) {
        if (countries[i].bytes == 0 || strlen(countries[i].code) != 2) {
            continue;
        }
        fprintf(file, "%s\"%s\":%llu", first ? "" : ",", countries[i].code, (unsigned long long)countries[i].bytes);
        first = 0;
    }
    if (other_bytes > 0) {
        fprintf(file, "%s\"OTHER\":%llu", first ? "" : ",", (unsigned long long)other_bytes);
    }
    fputs("}\n", file);
    if (fclose(file) != 0) {
        unlink(tmp);
        return;
    }
    chmod(tmp, 0644);
    if (rename(tmp, out_path) != 0) {
        unlink(tmp);
    }
}

static int listen_socket(void) {
    struct sockaddr_un addr;
    int fd;
    int rcv = 1 << 20;
    if (strlen(sock_path) >= sizeof addr.sun_path) {
        fprintf(stderr, "country counter socket path is too long\n");
        return -1;
    }
    unlink(sock_path);
    fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) {
        fprintf(stderr, "country counter could not open its socket\n");
        return -1;
    }
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, sock_path, strlen(sock_path));
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        fprintf(stderr, "country counter could not bind its socket\n");
        close(fd);
        return -1;
    }
    chmod(sock_path, 0666);
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof rcv);
    return fd;
}

int main(void) {
    int fd;
    char buf[MAX_MSG];
    struct sigaction action;

    sock_path = pick_path("DNS_MAGIC_GEO_SOCK", "/run/dns-magic-geo.sock");
    db_path = pick_path("DNS_MAGIC_GEO_DB", "/var/lib/dns-magic/geo/country.mmdb");
    out_path = pick_path("DNS_MAGIC_GEO_OUT", "/var/lib/dns-magic/stats/country.cumul");
    mkdir_one("/var/lib/dns-magic");
    mkdir_one("/var/lib/dns-magic/geo");
    mkdir_one("/var/lib/dns-magic/stats");
    mkdir_parent(sock_path);
    mkdir_parent(db_path);
    mkdir_parent(out_path);

    memset(&action, 0, sizeof action);
    action.sa_handler = on_stop;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    signal(SIGPIPE, SIG_IGN);

    fd = listen_socket();
    if (fd < 0) {
        return 1;
    }
    maybe_reload();
    write_totals();
    fprintf(stderr, "country counter listening\n");

    while (!stop_flag) {
        fd_set read_set;
        struct timeval wait;
        int ready;
        FD_ZERO(&read_set);
        FD_SET(fd, &read_set);
        wait.tv_sec = 10;
        wait.tv_usec = 0;
        ready = select(fd + 1, &read_set, NULL, NULL, &wait);
        if (stop_flag) {
            break;
        }
        maybe_reload();
        if (ready > 0) {
            for (;;) {
                ssize_t got = recv(fd, buf, sizeof buf - 1, MSG_DONTWAIT);
                if (got <= 0) {
                    break;
                }
                buf[got] = '\0';
                handle_message(buf, (size_t)got);
            }
        }
        write_totals();
    }
    write_totals();
    close(fd);
    unlink(sock_path);
    if (mmdb_open) {
        MMDB_close(&mmdb);
    }
    return 0;
}
