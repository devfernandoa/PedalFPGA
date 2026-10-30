/*
 * pedalctl - read/write the PedalFPGA registers (pedal_regs.vhd) from Linux on the HPS.
 *
 * The registers sit at offset 0 of the lightweight HPS-to-FPGA bridge (0xFF200000),
 * which u-boot enables (bridge_enable_handoff) after loading soc_system.rbf.
 *
 *   pedalctl id                       read ID (expect 0x50ED0003)
 *   pedalctl dump                     print every register
 *   pedalctl json                     state as JSON (for the web UI), presets included
 *   pedalctl chain <fx> [<fx> ...]    set the chain: audio goes through the effects in this order
 *                                     (up to 8, each at most once; names or 0..10)
 *   pedalctl chain none               empty chain (clean signal)
 *   pedalctl param <fx> <a> <b>       set knob A and knob B (0..31) of an effect
 *   pedalctl input line|mic           codec input (mic = mic jack with +20 dB boost)
 *   pedalctl cab on|off               cabinet simulator after the chain
 *   pedalctl volume <0..31>           output volume: 31 = 0 dB, 1.5 dB per step, 0 = mute
 *   pedalctl tune                     pitch of the input as JSON: {"hz":82.41,"note":"E2","cents":-3}
 *   pedalctl save|load|delete <name>  presets (chain + knobs + input + cab + volume) in PRESET_DIR
 *   pedalctl pitchtest                check the pitch detector on synthetic notes (no FPGA needed)
 */
#include <dirent.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LW_BRIDGE_BASE 0xFF200000u
#define MAP_SPAN       0x1000u

#define REG_ID      0
#define REG_CHAIN   1
#define REG_PARAM   2 /* PARAM[e] = REG_PARAM + e */
#define REG_CONFIG  13
#define REG_VOLUME  14
#define REG_CAPTURE 15
#define REG_CAPDATA 16

#define CFG_MIC 1u
#define CFG_CAB 2u

#define PEDAL_ID   0x50ED0003u
#define SLOT_EMPTY 0xFu
#define N_FX       11
#define N_REGS     15 /* CHAIN, PARAM[0..10], CONFIG, VOLUME: what a preset stores (registers 1..14) */

#define FS     48000
#define CAP_N  4096

#define PRESET_DIR "/home/root/presets"

static const char *fx_names[N_FX] = {
    "booster", "distortion", "overdrive", "tremolo", "delay", "wah", "phaser", "reverb",
    "compressor", "chorus", "flanger",
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

/* preset names: 1..24 of [a-z0-9], so they are safe as file names and in the CGI query string */
static int valid_name(const char *s)
{
    size_t n = strlen(s);
    if (n < 1 || n > 24)
        return 0;
    for (size_t i = 0; i < n; i++)
        if (!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= '0' && s[i] <= '9')))
            return 0;
    return 1;
}

static int usage(void)
{
    fprintf(stderr,
            "usage: pedalctl id | dump | json | chain none | chain <fx>... | param <fx> <a> <b>\n"
            "                | input line|mic | cab on|off | volume <0..31> | tune\n"
            "                | save|load|delete <name> | pitchtest\n"
            "  fx: booster distortion overdrive tremolo delay wah phaser reverb compressor chorus flanger (or 0..10)\n"
            "  a, b: 0..31;  name: 1..24 of a-z 0-9\n");
    return 2;
}

/* ------------------------------------------------------------------ pitch (YIN) */

/* Fundamental of x[0..n) in Hz, or 0 if there is no clear pitch (silence, noise, a chord).
 * YIN (de Cheveigne & Kawahara 2002): cumulative-mean-normalized difference, first dip under
 * 0.15, parabolic interpolation. Range 70 Hz (drop D) .. 1000 Hz. */
static double detect_pitch(const double *x, int n)
{
    enum { W = 2048, TAU_MIN = FS / 1000, TAU_MAX = FS / 70 };
    static double d[TAU_MAX + 2];
    if (n < W + TAU_MAX + 1)
        return 0;

    double energy = 0;
    for (int j = 0; j < W; j++)
        energy += x[j] * x[j];
    if (sqrt(energy / W) < 60) /* about -55 dBFS: nothing playing */
        return 0;

    double sum = 0;
    d[0] = 1;
    for (int tau = 1; tau <= TAU_MAX + 1; tau++) {
        double s = 0;
        for (int j = 0; j < W; j++) {
            double v = x[j] - x[j + tau];
            s += v * v;
        }
        sum += s;
        d[tau] = sum > 0 ? s * tau / sum : 1;
    }

    int best = -1;
    for (int tau = TAU_MIN; tau <= TAU_MAX; tau++) {
        if (d[tau] < 0.15) {
            while (tau + 1 <= TAU_MAX && d[tau + 1] < d[tau])
                tau++;
            best = tau;
            break;
        }
    }
    if (best < 0)
        return 0;

    double a = d[best - 1], b = d[best], c = d[best + 1];
    double den = a - 2 * b + c;
    double t = best + (den != 0 ? 0.5 * (a - c) / den : 0);
    return FS / t;
}

static void print_pitch(double hz)
{
    static const char *names[12] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
    if (hz <= 0) {
        printf("{\"hz\":0}\n");
        return;
    }
    double midi = 69 + 12 * log2(hz / 440);
    int m = (int)lround(midi);
    printf("{\"hz\":%.2f,\"note\":\"%s%d\",\"cents\":%d}\n", hz, names[((m % 12) + 12) % 12], m / 12 - 1,
           (int)lround(100 * (midi - m)));
}

/* Synthetic plucked notes (decaying harmonics, a little noise) through the detector: each must come
 * out within 2 cents, and silence must give no pitch. */
static int pitchtest(void)
{
    static double x[CAP_N];
    const double notes[] = {73.42, 82.41, 110.0, 146.83, 196.0, 246.94, 329.63, 440.0 * 1.00579 /* +10 cents */,
                            659.26, 987.77};
    int bad = 0;
    srand(1);
    for (size_t k = 0; k < sizeof notes / sizeof notes[0]; k++) {
        double f = notes[k];
        for (int i = 0; i < CAP_N; i++) {
            double t = (double)i / FS, v = 0;
            for (int h = 1; h <= 8; h++)
                v += sin(2 * M_PI * f * h * t + h) * exp(-t * 3 * h) / h;
            x[i] = 6000 * v + (rand() % 201 - 100);
        }
        double got = detect_pitch(x, CAP_N);
        double cents = got > 0 ? 1200 * log2(got / f) : 1e9;
        printf("%8.2f Hz -> %8.2f Hz (%+.2f cents)\n", f, got, cents);
        bad += fabs(cents) > 2;
    }
    for (int i = 0; i < CAP_N; i++)
        x[i] = rand() % 41 - 20;
    double got = detect_pitch(x, CAP_N);
    printf("silence  -> %.2f Hz\n", got);
    bad += got != 0;
    printf(bad ? "FAILED\n" : "pitch ok\n");
    return bad != 0;
}

static int tune(volatile uint32_t *regs)
{
    static double x[CAP_N];
    regs[REG_CAPTURE] = 1;
    struct timespec ms = {0, 1000000};
    int waited = 0;
    while (!(regs[REG_CAPTURE] & 1)) { /* 4096 samples = 85 ms */
        if (++waited > 500) {
            fprintf(stderr, "capture did not finish (is audio running?)\n");
            return 1;
        }
        nanosleep(&ms, NULL);
    }
    regs[REG_CAPDATA] = 0; /* rewind */
    for (int i = 0; i < CAP_N; i++)
        x[i] = (int32_t)regs[REG_CAPDATA];
    print_pitch(detect_pitch(x, CAP_N));
    return 0;
}

/* ------------------------------------------------------------------ presets */

static int preset_path(char *buf, size_t n, const char *name)
{
    if (!valid_name(name)) {
        fprintf(stderr, "bad preset name '%s' (1..24 of a-z 0-9)\n", name);
        return -1;
    }
    snprintf(buf, n, "%s/%s", PRESET_DIR, name);
    return 0;
}

/* a preset file is the raw values of registers 1..14, one hex number per line */
static int preset_save(volatile uint32_t *regs, const char *name)
{
    char path[128];
    if (preset_path(path, sizeof path, name))
        return 2;
    mkdir(PRESET_DIR, 0755);
    FILE *f = fopen(path, "w");
    if (!f) {
        perror(path);
        return 1;
    }
    for (int r = 1; r < N_REGS; r++)
        fprintf(f, "0x%08X\n", regs[r]);
    fclose(f);
    sync();
    return 0;
}

static int preset_load(volatile uint32_t *regs, const char *name)
{
    char path[128];
    uint32_t v[N_REGS];
    if (preset_path(path, sizeof path, name))
        return 2;
    FILE *f = fopen(path, "r");
    if (!f) {
        perror(path);
        return 1;
    }
    int ok = 1;
    for (int r = 1; r < N_REGS && ok; r++)
        ok = fscanf(f, "%x", &v[r]) == 1;
    fclose(f);
    if (!ok) {
        fprintf(stderr, "%s: not a preset file\n", path);
        return 1;
    }
    for (int r = 1; r < N_REGS; r++)
        regs[r] = v[r];
    return 0;
}

static int cmp_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

/* preset names as a JSON array, sorted */
static void print_presets(void)
{
    char *names[256];
    int n = 0;
    DIR *d = opendir(PRESET_DIR);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)) && n < 256)
            if (valid_name(e->d_name))
                names[n++] = strdup(e->d_name);
        closedir(d);
    }
    qsort(names, n, sizeof names[0], cmp_str);
    printf("[");
    for (int i = 0; i < n; i++) {
        printf("%s\"%s\"", i ? "," : "", names[i]);
        free(names[i]);
    }
    printf("]");
}

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv)
{
    if (argc < 2)
        return usage();
    const char *cmd = argv[1];
    if (strcmp(cmd, "pitchtest") == 0)
        return pitchtest();

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
        fprintf(stderr, "unexpected ID 0x%08X (want 0x%08X): is soc_system.rbf on the SD card up to date?\n", id,
                PEDAL_ID);
        return 1;
    }

    int ret = 0;
    if (strcmp(cmd, "id") == 0) {
        printf("0x%08X\n", id);
    } else if (strcmp(cmd, "dump") == 0) {
        uint32_t chain = regs[REG_CHAIN], cfg = regs[REG_CONFIG];
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
        printf("CONFIG 0x%X: input %s, cab %s\n", cfg, cfg & CFG_MIC ? "mic" : "line", cfg & CFG_CAB ? "on" : "off");
        printf("VOLUME %u\n", regs[REG_VOLUME] & 31);
    } else if (strcmp(cmd, "json") == 0) {
        /* {"chain":["delay",...],"params":{"booster":[a,b],...},"input":"line","cab":false,"volume":31,"presets":[...]} */
        uint32_t chain = regs[REG_CHAIN], cfg = regs[REG_CONFIG];
        printf("{\"chain\":[");
        for (int s = 0, n = 0; s < 8; s++) {
            unsigned fx = (chain >> (4 * s)) & 0xF;
            if (fx < N_FX)
                printf("%s\"%s\"", n++ ? "," : "", fx_names[fx]);
        }
        printf("],\"params\":{");
        for (int e = 0; e < N_FX; e++) {
            uint32_t p = regs[REG_PARAM + e];
            printf("%s\"%s\":[%u,%u]", e ? "," : "", fx_names[e], (p >> 5) & 31, p & 31);
        }
        printf("},\"input\":\"%s\",\"cab\":%s,\"volume\":%u,\"presets\":", cfg & CFG_MIC ? "mic" : "line",
               cfg & CFG_CAB ? "true" : "false", regs[REG_VOLUME] & 31);
        print_presets();
        printf("}\n");
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
    } else if (strcmp(cmd, "input") == 0 && argc == 3 && (!strcmp(argv[2], "line") || !strcmp(argv[2], "mic"))) {
        uint32_t cfg = regs[REG_CONFIG] & ~CFG_MIC;
        regs[REG_CONFIG] = cfg | (strcmp(argv[2], "mic") == 0 ? CFG_MIC : 0);
    } else if (strcmp(cmd, "cab") == 0 && argc == 3 && (!strcmp(argv[2], "on") || !strcmp(argv[2], "off"))) {
        uint32_t cfg = regs[REG_CONFIG] & ~CFG_CAB;
        regs[REG_CONFIG] = cfg | (strcmp(argv[2], "on") == 0 ? CFG_CAB : 0);
    } else if (strcmp(cmd, "volume") == 0 && argc == 3) {
        int v = parse_knob(argv[2]);
        if (v < 0)
            return usage();
        regs[REG_VOLUME] = (uint32_t)v;
    } else if (strcmp(cmd, "tune") == 0) {
        ret = tune(regs);
    } else if (strcmp(cmd, "save") == 0 && argc == 3) {
        ret = preset_save(regs, argv[2]);
    } else if (strcmp(cmd, "load") == 0 && argc == 3) {
        ret = preset_load(regs, argv[2]);
    } else if (strcmp(cmd, "delete") == 0 && argc == 3) {
        char path[128];
        ret = preset_path(path, sizeof path, argv[2]) ? 2 : (unlink(path) ? (perror(path), 1) : 0);
    } else {
        ret = usage();
    }

    munmap((void *)regs, MAP_SPAN);
    return ret;
}
