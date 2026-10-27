/*
 * pedalctl - read/write the PedalFPGA registers (pedal_regs.vhd) from Linux on the HPS.
 *
 * The registers sit at offset 0 of the lightweight HPS-to-FPGA bridge (0xFF200000),
 * which u-boot enables (bridge_enable_handoff) after loading soc_system.rbf.
 *
 *   pedalctl id                       read ID (expect 0x50ED0001)
 *   pedalctl dump                     print every register
 *   pedalctl chain <fx> [<fx> ...]    set the chain: audio goes through the effects in this order
 *                                     (up to 8, each at most once; names or 0..7)
 *   pedalctl chain none               empty chain (clean signal)
 *   pedalctl param <fx> <a> <b>       set knob A and knob B (0..31) of an effect
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define LW_BRIDGE_BASE 0xFF200000u
#define MAP_SPAN       0x1000u

#define REG_ID    0
#define REG_CHAIN 1
#define REG_PARAM 2 /* PARAM[e] = REG_PARAM + e */

#define PEDAL_ID   0x50ED0001u
#define SLOT_EMPTY 0xFu
#define N_FX       8

static const char *fx_names[N_FX] = {
    "booster", "distortion", "overdrive", "tremolo", "delay", "wah", "phaser", "reverb",
};

static int parse_fx(const char *s)
{
    for (int e = 0; e < N_FX; e++)
        if (strcmp(s, fx_names[e]) == 0)
            return e;
    char *end;
    long e = strtol(s, &end, 10);
    return (*end == '\0' && e >= 0 && e < N_FX) ? (int)e : -1;
}

static int parse_knob(const char *s)
{
    char *end;
    long v = strtol(s, &end, 10);
    return (*end == '\0' && v >= 0 && v <= 31) ? (int)v : -1;
}

static int usage(void)
{
    fprintf(stderr,
            "usage: pedalctl id | dump | chain none | chain <fx>... | param <fx> <a> <b>\n"
            "  fx: booster distortion overdrive tremolo delay wah phaser reverb (or 0..7)\n"
            "  a, b: 0..31\n");
    return 2;
}

int main(int argc, char **argv)
{
    if (argc < 2)
        return usage();

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (run as root)");
        return 1;
    }
    volatile uint32_t *regs = mmap(NULL, MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LW_BRIDGE_BASE);
    close(fd);
    if (regs == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    /* If the FPGA isn't configured with our design (or the bridge is off) this is the
     * first access that fails: either a wrong ID or a bus error. */
    uint32_t id = regs[REG_ID];
    if (id != PEDAL_ID) {
        fprintf(stderr, "unexpected ID 0x%08X (want 0x%08X): is soc_system.rbf on the SD card?\n", id, PEDAL_ID);
        return 1;
    }

    const char *cmd = argv[1];
    if (strcmp(cmd, "id") == 0) {
        printf("0x%08X\n", id);
    } else if (strcmp(cmd, "dump") == 0) {
        uint32_t chain = regs[REG_CHAIN];
        printf("CHAIN 0x%08X:", chain);
        for (int s = 0; s < 8; s++) {
            unsigned fx = (chain >> (4 * s)) & 0xF;
            printf(" %s", fx < N_FX ? fx_names[fx] : "-");
        }
        printf("\n");
        for (int e = 0; e < N_FX; e++) {
            uint32_t p = regs[REG_PARAM + e];
            printf("%-10s A=%2u B=%2u\n", fx_names[e], (p >> 5) & 31, p & 31);
        }
    } else if (strcmp(cmd, "chain") == 0) {
        if (argc < 3 || argc > 2 + 8)
            return usage();
        uint32_t chain = 0xFFFFFFFFu;
        if (!(argc == 3 && strcmp(argv[2], "none") == 0)) {
            unsigned used = 0;
            for (int s = 0; s < argc - 2; s++) {
                int fx = parse_fx(argv[2 + s]);
                if (fx < 0)
                    return usage();
                /* each effect exists once in the FPGA; twice in the chain would step it twice per sample */
                if (used & (1u << fx)) {
                    fprintf(stderr, "%s is already in the chain\n", fx_names[fx]);
                    return 2;
                }
                used |= 1u << fx;
                chain &= ~(0xFu << (4 * s));
                chain |= (uint32_t)fx << (4 * s);
            }
        }
        regs[REG_CHAIN] = chain;
    } else if (strcmp(cmd, "param") == 0) {
        if (argc != 5)
            return usage();
        int fx = parse_fx(argv[2]), a = parse_knob(argv[3]), b = parse_knob(argv[4]);
        if (fx < 0 || a < 0 || b < 0)
            return usage();
        regs[REG_PARAM + fx] = ((uint32_t)a << 5) | (uint32_t)b;
    } else {
        return usage();
    }

    munmap((void *)regs, MAP_SPAN);
    return 0;
}
