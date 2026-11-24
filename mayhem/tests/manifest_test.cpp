// Known-answer tests for Code/PocketMageOS/src/elf_app_manifest.cpp (app.properties parser
// and scope gating). Prints one "PASS <name>"/"FAIL <name>" line per case.
#include <elf_app_manifest.h>
#include <stdio.h>
#include <string.h>

static int g_fail = 0;
static void check(bool ok, const char *name) {
  printf("%s %s\n", ok ? "PASS" : "FAIL", name);
  if (!ok) g_fail++;
}

int main() {
  ElfAppManifest m;
  const char *t1 = "# comment\r\nname = Hello World\nversion=1.2.0 beta\n; x\n"
                   "author=Jane Doe\nscope= sd, eink ,pm_kb_\nunknown=1\n";
  int n = elfManifestParse(t1, strlen(t1), m);
  check(n == 4, "parse_field_count");
  check(!strcmp(m.name, "Hello"), "name_stops_at_space");
  check(!strcmp(m.version, "1.2.0"), "version_stops_at_space");
  check(!strcmp(m.author, "Jane Doe"), "author_keeps_spaces");
  check(!strcmp(m.scope, "sd, eink ,pm_kb_"), "scope_raw");

  const char *t2 = "name=ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n";
  elfManifestParse(t2, strlen(t2), m);
  check(strlen(m.name) == 31 && !strncmp(m.name, "ABCDEFGHIJKLMNOPQRSTUVWXYZ01234", 31), "name_truncated");
  check(elfManifestParse("", 0, m) == 0 && m.name[0] == 0, "empty_input");
  check(elfManifestParse("namex=1\nname : 2\n", 17, m) == 0, "malformed_keys_ignored");

  ElfAppScope s;
  elfScopeFromManifest(" sd, eink ,pm_kb_", s);
  check(!s.all && s.count == 3, "scope_token_count");
  check(!strcmp(s.prefix[0], "pm_sd_") && !strcmp(s.prefix[1], "pm_eink_") && !strcmp(s.prefix[2], "pm_kb_"),
        "scope_prefixes");
  check(elfScopeAllows(s, "pm_sd_open") && !elfScopeAllows(s, "pm_oled_draw"), "scope_gates_pm");
  check(elfScopeAllows(s, "memcpy"), "scope_passes_non_pm");
  elfScopeFromManifest("sd,ALL", s);
  check(s.all && elfScopeAllows(s, "pm_oled_draw"), "scope_all");
  elfScopeFromManifest(" , ,", s);
  check(s.all, "scope_no_tokens_means_all");

  printf("manifest tests: %d failed\n", g_fail);
  return g_fail ? 1 : 0;
}
