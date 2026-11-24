// Fuzzes the installed-app manifest (app.properties) parser of PocketMageOS
// (Code/PocketMageOS/src/elf_app_manifest.cpp), the way elf_runner.cpp uses it:
// readElfAppProperties() reads at most ELF_APP_PROPERTIES_MAX_BYTES of the SD-card
// file into a buffer and calls elfManifestParse(); the parsed scope string then
// goes through elfScopeFromManifest() and gates every symbol via elfScopeAllows().
#include <elf_app_manifest.h>
#include <elf_runner_limits.h>

#include <stddef.h>
#include <stdint.h>
#include <string.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  // elf_runner.cpp rejects files larger than ELF_APP_PROPERTIES_MAX_BYTES before parsing.
  if (size > kElfAppPropertiesMaxBytes) return -1;
  char text[kElfAppPropertiesMaxBytes];
  memcpy(text, data, size);

  ElfAppManifest m;
  elfManifestParse(text, size, m);

  ElfAppScope s;
  elfScopeFromManifest(m.scope, s);

  // Symbol names the resolver sees: a few SDK/libc names, and the manifest's own
  // name/author fields used as symbol names (NUL-terminated by the parser).
  static const char *const kSyms[] = {"pm_sd_open", "pm_eink_draw", "pm_", "pm",
                                      "memcpy",     "pm_kb_get",    ""};
  volatile int allowed = 0;
  for (const char *sym : kSyms) allowed += elfScopeAllows(s, sym);
  allowed += elfScopeAllows(s, m.name);
  allowed += elfScopeAllows(s, m.author);
  allowed += elfScopeAllows(s, m.version);
  (void)allowed;
  return 0;
}
