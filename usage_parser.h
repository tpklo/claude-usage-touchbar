// Strict, portable parser for claude-touchbar.sh --raw output.
// The line-oriented approach builds on @xmihal03's PR #1. Scan backwards
// so both login banners and trailing shell diagnostics can be ignored.
#pragma once
#include <limits.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    int p5, p7, resetMin, ageSec, scopedPct;
    char state[8];
    char scopedName[65];
} UsageReading;

typedef struct { const char *text; size_t length; } UsageToken;

static int UsageTokenEquals(UsageToken token, const char *value) {
    return token.length == strlen(value) &&
           memcmp(token.text, value, token.length) == 0;
}

static int UsageInteger(UsageToken token, int maximum, int *result) {
    // Only the protocol's unknown sentinel may be negative. No signs,
    // decimals, suffixes or locale-dependent conversion; decimal zeros are OK.
    if (UsageTokenEquals(token, "-1")) { *result = -1; return 1; }
    if (token.length == 0 || token.length > 10) return 0;
    int value = 0;
    for (size_t i = 0; i < token.length; ++i) {
        unsigned char c = (unsigned char)token.text[i];
        if (c < '0' || c > '9') return 0;
        int digit = c - '0';
        if (value > maximum / 10 ||
            (value == maximum / 10 && digit > maximum % 10)) return 0;
        value = value * 10 + digit;
    }
    *result = value;
    return 1;
}

static int ParseUsageLine(const char *text, size_t length, UsageReading *out) {
    if (length == 0 || length > 512) return 0;
    UsageToken fields[7];
    size_t count = 0, i = 0;
    while (i < length) {
        while (i < length && (text[i] == ' ' || text[i] == '\t')) ++i;
        if (i == length) break;
        if (count == 7) return 0;
        size_t start = i;
        while (i < length && text[i] != ' ' && text[i] != '\t') ++i;
        fields[count++] = (UsageToken){text + start, i - start};
    }
    if (count < 5) return 0;
    UsageReading candidate = {0};
    candidate.scopedPct = -1;
    if (!UsageInteger(fields[0], 100, &candidate.p5) ||
        !UsageInteger(fields[1], 100, &candidate.p7) ||
        !UsageInteger(fields[2], 525600, &candidate.resetMin) ||
        !UsageInteger(fields[3], INT_MAX, &candidate.ageSec)) return 0;
    if (!(UsageTokenEquals(fields[4], "ok") || UsageTokenEquals(fields[4], "stale") ||
          UsageTokenEquals(fields[4], "expired") || UsageTokenEquals(fields[4], "none"))) return 0;
    memcpy(candidate.state, fields[4].text, fields[4].length);
    if (count >= 6 && !UsageInteger(fields[5], 100, &candidate.scopedPct)) return 0;
    if (count == 7) {
        UsageToken name = fields[6];
        if (name.length == 0 || name.length > 64) return 0;
        for (size_t j = 0; j < name.length; ++j) {
            unsigned char c = (unsigned char)name.text[j];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-')) return 0;
        }
        memcpy(candidate.scopedName, name.text, name.length);
    }
    *out = candidate;
    return 1;
}

static int ParseUsageOutput(const char *text, size_t length, UsageReading *out) {
    if (!text || !out || length == 0 || length > 65536) return 0;
    // Reject embedded NUL rather than allowing callers to disagree on length.
    if (memchr(text, '\0', length)) return 0;
    size_t end = length;
    while (end > 0) {
        while (end > 0 && (text[end - 1] == '\n' || text[end - 1] == '\r')) --end;
        if (end == 0) break;
        size_t start = end;
        while (start > 0 && text[start - 1] != '\n' && text[start - 1] != '\r') --start;
        if (ParseUsageLine(text + start, end - start, out)) return 1;
        end = start;
    }
    return 0;
}
