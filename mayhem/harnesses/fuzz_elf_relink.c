// Fuzzes elf_overlay's relink host tool (lib/elf_overlay/tools/relink/main.c with
// tools/common/elf_read.c, reloc.c, blob_pack.c): it parses an app ELF's sections,
// symbols and relocations and packs a .relk manifest. The tool's main() is compiled
// as relink_main() (-Dmain=relink_main) and run on the input written to a scratch file,
// with its output in the scratch dir too.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int relink_main(int argc, char **argv);

static char g_in[4096], g_out[4096];

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc; (void)argv;
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    snprintf(g_in, sizeof(g_in), "%s/fuzz_relink_in_XXXXXX", tmp);
    snprintf(g_out, sizeof(g_out), "%s/fuzz_relink_out_XXXXXX", tmp);
    int a = mkstemp(g_in), b = mkstemp(g_out);
    if (a < 0 || b < 0) abort();
    close(a); close(b);
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!g_in[0]) LLVMFuzzerInitialize(NULL, NULL);
    FILE *fp = fopen(g_in, "wb");
    if (!fp) abort();
    if (size && fwrite(data, 1, size, fp) != size) abort();
    fclose(fp);
    char *argv[] = {(char *)"elf_overlay_relink", g_in, g_out, NULL};
    int saved = dup(1);  // the tool prints progress on stdout
    FILE *null = fopen("/dev/null", "w");
    if (null) { fflush(stdout); dup2(fileno(null), 1); }
    relink_main(3, argv);
    if (null) { fflush(stdout); dup2(saved, 1); fclose(null); }
    close(saved);
    return 0;
}
