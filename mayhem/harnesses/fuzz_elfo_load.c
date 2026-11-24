// Fuzzes the elf_overlay loader (lib/elf_overlay: core/loader.c, core/blob.c, the
// xtensa/riscv patchers, the POSIX port) through its public API, on an ELFO overlay
// blob as PocketMageOS reads it from the SD card. The input is written to a scratch
// file and loaded with elf_overlay_load(path) (elf_overlay_load_from_memory is a stub
// that always returns ELF_OVERLAY_ERR_UNSUPPORTED). Every overlay listed in the blob
// is then paged in with elf_overlay_enter() — the page-in copies the body into a frame
// and applies patches, stub patches and host refs; it never runs the loaded code.
#include "elf_overlay/overlay_loader.h"
#include "elf_overlay/overlay_format.h"
#include "elf_overlay/errors.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void elf_overlay_xtensa_init(void);
void elf_overlay_riscv_init(void);

static char g_path[4096];

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc; (void)argv;
    elf_overlay_xtensa_init();
    elf_overlay_riscv_init();
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    snprintf(g_path, sizeof(g_path), "%s/fuzz_elfo_XXXXXX", tmp);
    int fd = mkstemp(g_path);
    if (fd < 0) abort();
    close(fd);
    return 0;
}

// Deterministic host-symbol resolver: names starting with "pm_" or "mem" resolve.
static uintptr_t resolver(const char *name) {
    if (!name) return 0;
    if (!strncmp(name, "pm_", 3) || !strncmp(name, "mem", 3)) return 0x3fc80000u + (uintptr_t)(unsigned char)name[0];
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (!g_path[0]) LLVMFuzzerInitialize(NULL, NULL);
    FILE *fp = fopen(g_path, "wb");
    if (!fp) abort();
    if (size && fwrite(data, 1, size, fp) != size) abort();
    fclose(fp);

    elf_overlay_loader_t *l = NULL;
    if (elf_overlay_load(&l, g_path) != ELF_OVERLAY_OK || !l) return 0;

    elf_overlay_set_symbol_resolver(l, resolver);

    // Two canonical windows mapped onto fake resident ranges; resolve() is arithmetic only.
    elf_overlay_section_map_t map;
    memset(&map, 0, sizeof(map));
    map.entries[0].v_addr = 0x00000000u; map.entries[0].addr = 0x40000000u; map.entries[0].size = 0x40000000u;
    map.entries[1].v_addr = 0x40000000u; map.entries[1].addr = 0x3c000000u; map.entries[1].size = 0x01000000u;
    elf_overlay_set_section_map(l, &map);

    (void)elf_overlay_get_stub_block(l);
    volatile size_t fs = elf_overlay_get_frame_size(l) + elf_overlay_get_frame_count(l);
    (void)fs;

    elf_overlay_header_t hdr;
    memcpy(&hdr, data, sizeof(hdr));  // load succeeded, so the header was read in full

    elf_overlay_set_active(l);
    size_t ov_tab = sizeof(hdr);
    for (unsigned i = 0; i < hdr.overlays && i < 64; i++) {
        size_t off = ov_tab + (size_t)i * sizeof(elf_overlay_entry_t);
        if (off + sizeof(elf_overlay_entry_t) > size) break;
        elf_overlay_entry_t ov;
        memcpy(&ov, data + off, sizeof(ov));
        uint32_t key = ((uint32_t)ov.id << 16) | (i & 3u);
        if (elf_overlay_enter(key)) elf_overlay_leave(key);
    }
    size_t stub_tab = ov_tab + (size_t)hdr.overlays * sizeof(elf_overlay_entry_t);
    for (unsigned i = 0; i < hdr.stubs && i < 64; i++) {
        size_t off = stub_tab + (size_t)i * sizeof(elf_overlay_stub_t);
        if (off + sizeof(elf_overlay_stub_t) > size) break;
        elf_overlay_stub_t st;
        memcpy(&st, data + off, sizeof(st));
        uint32_t so = 0, res = 0;
        elf_overlay_find_stub(l, st.canonical, &so);
        elf_overlay_resolve(l, st.canonical, &res);
    }
    elf_overlay_set_active(NULL);
    elf_overlay_unload(l);
    return 0;
}
