/* Exercise the actual native parser without Cocoa, credentials or networking. */
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../usage_parser.h"

static unsigned checks;

static void expect_reading(const char *text, size_t length,
                           int p5, int p7, int reset, int age,
                           const char *state, int scoped, const char *name) {
    UsageReading out;
    memset(&out, 0xa5, sizeof(out));
    assert(ParseUsageOutput(text, length, &out) == 1);
    assert(out.p5 == p5);
    assert(out.p7 == p7);
    assert(out.resetMin == reset);
    assert(out.ageSec == age);
    assert(strcmp(out.state, state) == 0);
    assert(out.scopedPct == scoped);
    assert(strcmp(out.scopedName, name) == 0);
    checks++;
}

static void good(const char *text, int p5, int p7, int reset, int age,
                 const char *state, int scoped, const char *name) {
    expect_reading(text, strlen(text), p5, p7, reset, age, state, scoped, name);
}

static void invalid_bytes(const char *text, size_t length) {
    UsageReading out, before;
    memset(&out, 0xa5, sizeof(out));
    memcpy(&before, &out, sizeof(out));
    assert(ParseUsageOutput(text, length, &out) == 0);
    assert(memcmp(&out, &before, sizeof(out)) == 0);
    checks++;
}

static void bad(const char *text) { invalid_bytes(text, strlen(text)); }

int main(void) {
    good("37 8 20 0 ok\n", 37, 8, 20, 0, "ok", -1, "");
    good("37 8 20 0 ok", 37, 8, 20, 0, "ok", -1, "");
    good("37 8 20 0 stale 18\n", 37, 8, 20, 0, "stale", 18, "");
    good("37 8 20 0 expired 18 Claude-Fable_5.1\n", 37, 8, 20, 0,
         "expired", 18, "Claude-Fable_5.1");
    good("-1 -1 -1 -1 none -1 -\n", -1, -1, -1, -1, "none", -1, "-");
    good("0000000008 009 020 000 ok\n", 8, 9, 20, 0, "ok", -1, "");
    good("0 100 525600 0 ok 100 -\n", 0, 100, 525600, 0, "ok", 100, "-");
    good("  \t37\t8  20\t0 ok\t18\tname \t\r\n", 37, 8, 20, 0,
         "ok", 18, "name");
    good("37 8 20 0 ok\nwarning: trailing diagnostic\n", 37, 8, 20, 0, "ok", -1, "");
    good("debug start\n\n37 8 20 0 ok\n\n", 37, 8, 20, 0, "ok", -1, "");
    good("1 2 3 4 ok\n37 8 20 0 stale 18 model\ntrailing noise\n",
         37, 8, 20, 0, "stale", 18, "model");
    good("1 2 3 4 ok\n101 2 3 4 ok\n", 1, 2, 3, 4, "ok", -1, "");

    bad(""); bad("\n\r\n \t\n"); bad("noise only\n");
    bad("37 8 20 ok\n"); bad("37 8 20 0 ok 2 name extra\n");
    bad("37 8 20 0 okay\n"); bad("37 8 20 0 OK\n");
    bad("37 8 20 0 unknown\n"); bad("37 8 20 0 okkkkkkk\n");
    bad("37 8 20 0 ok name\n"); bad("37 8 20 0 ok 2 bad/name\n");
    bad("37 8 20 0 ok 2 name;command\n");
    bad("37 8 20 0 ok 2 caf\xc3\xa9\n");
    bad("37 8 20 0 ok 2 x\x01\n");
    bad("37 8 20 0 ok\v\n");

    const char *malformed[] = {
        "", "-", "--1", "+1", "-0", "-01", "00000000001", "1x", "0x10", "1.0", "1e2", "NaN", "inf",
        "2147483648", "-2147483649", "999999999999999999999999999999999",
        "a[$(touch${IFS}/tmp/not-executed)]"
    };
    for (size_t i = 0; i < sizeof(malformed)/sizeof(malformed[0]); i++) {
        for (int field = 0; field < 5; field++) {
            const char *v[5] = {"37", "8", "20", "0", "18"};
            v[field] = malformed[i];
            char line[512];
            snprintf(line, sizeof(line), "%s %s %s %s ok %s model\n",
                     v[0], v[1], v[2], v[3], v[4]);
            bad(line);
        }
    }
    const char *ranges[] = {
        "101 8 20 0 ok\n", "-2 8 20 0 ok\n", "37 101 20 0 ok\n",
        "37 -2 20 0 ok\n", "37 8 -2 0 ok\n", "37 8 525601 0 ok\n",
        "37 8 20 -2 ok\n", "37 8 20 0 ok 101\n", "37 8 20 0 ok -2\n"
    };
    for (size_t i = 0; i < sizeof(ranges)/sizeof(ranges[0]); i++) bad(ranges[i]);
    char boundary[256];
    snprintf(boundary, sizeof(boundary), "1 2 3 %d ok\n", INT_MAX);
    good(boundary, 1, 2, 3, INT_MAX, "ok", -1, "");

    char name[66];
    memset(name, 'a', 64); name[64] = '\0';
    snprintf(boundary, sizeof(boundary), "1 2 3 4 ok 5 %s\n", name);
    good(boundary, 1, 2, 3, 4, "ok", 5, name);
    name[64] = 'a'; name[65] = '\0';
    snprintf(boundary, sizeof(boundary), "1 2 3 4 ok 5 %s\n", name);
    bad(boundary);

    /* The caller supplies a byte length, not necessarily a NUL-terminated string. */
    const char raw[] = {'1',' ','2',' ','3',' ','4',' ','o','k'};
    expect_reading(raw, sizeof(raw), 1, 2, 3, 4, "ok", -1, "");
    const char embedded[] = "1 2 3 4 ok\0hidden\n";
    invalid_bytes(embedded, sizeof(embedded) - 1);
    expect_reading(embedded, 10, 1, 2, 3, 4, "ok", -1, "");

    char longline[600];
    memset(longline, ' ', sizeof(longline));
    memcpy(longline, "1 2 3 4 ok", 10);
    longline[sizeof(longline)-1] = '\n';
    invalid_bytes(longline, sizeof(longline));
    expect_reading(longline, 512, 1, 2, 3, 4, "ok", -1, "");
    invalid_bytes(longline, 513);
    char noisy[700];
    const char *valid = "37 8 20 0 ok\n";
    size_t validlen = strlen(valid);
    memcpy(noisy, longline, sizeof(longline));
    memcpy(noisy + sizeof(longline), valid, validlen);
    expect_reading(noisy, sizeof(longline) + validlen, 37, 8, 20, 0, "ok", -1, "");

    char *large = malloc(65537);
    assert(large != NULL);
    memset(large, '\n', 65537);
    memcpy(large + 65536 - validlen, valid, validlen);
    expect_reading(large, 65536, 37, 8, 20, 0, "ok", -1, "");
    invalid_bytes(large, 65537);
    free(large);
    invalid_bytes(NULL, 0);
    invalid_bytes(NULL, 10);
    assert(ParseUsageOutput("1 2 3 4 ok", 10, NULL) == 0);

    /* Reproducible malformed byte inputs; sanitizers catch overreads/UB while
       these assertions enforce the parser's all-or-nothing output contract. */
    uint32_t seed = UINT32_C(0x21a589f3);
    for (unsigned iteration = 0; iteration < 30000; iteration++) {
        char bytes[600];
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        size_t length = seed % sizeof(bytes);
        for (size_t i = 0; i < length; i++) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
            bytes[i] = (char)(seed & 255);
        }
        if (iteration % 2 == 0 && length >= validlen)
            memcpy(bytes + length - validlen, valid, validlen);
        UsageReading out, before;
        memset(&out, 0xa5, sizeof(out));
        memcpy(&before, &out, sizeof(out));
        int result = ParseUsageOutput(bytes, length, &out);
        assert(result == 0 || result == 1);
        if (!result) {
            assert(memcmp(&out, &before, sizeof(out)) == 0);
        } else {
            assert(out.p5 >= -1 && out.p5 <= 100);
            assert(out.p7 >= -1 && out.p7 <= 100);
            assert(out.resetMin >= -1 && out.resetMin <= 525600);
            assert(out.ageSec >= -1);
            assert(out.scopedPct >= -1 && out.scopedPct <= 100);
            assert(memchr(out.state, 0, sizeof(out.state)) != NULL);
            assert(memchr(out.scopedName, 0, sizeof(out.scopedName)) != NULL);
        }
        checks++;
    }
    printf("usage parser: %u checks passed\n", checks);
    return 0;
}
