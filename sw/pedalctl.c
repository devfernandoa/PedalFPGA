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
 *   pedalctl panel                    front panel: HPS_KEY cycles presets, the LCD shows the name (runs forever)
 *   pedalctl pitchtest                check the pitch detector on synthetic notes (no FPGA needed)
 *   pedalctl paneltest                print a sample LCD screen as text (no board needed)
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
#define CURRENT_FILE PRESET_DIR "/.current" /* name of the last preset loaded (survives power-off) */

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
            "                | save|load|delete <name> | panel | pitchtest | paneltest\n"
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
    FILE *c = fopen(CURRENT_FILE, "w"); /* so the panel and the next boot know which one is on */
    if (c) {
        fprintf(c, "%s\n", name);
        fclose(c);
    }
    return 0;
}

static int cmp_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

#define MAX_PRESETS 256

/* sorted preset names into names[] (caller frees), returns the count */
static int list_presets(char **names)
{
    int n = 0;
    DIR *d = opendir(PRESET_DIR);
    if (d) {
        struct dirent *e;
        while ((e = readdir(d)) && n < MAX_PRESETS)
            if (valid_name(e->d_name))
                names[n++] = strdup(e->d_name);
        closedir(d);
    }
    qsort(names, n, sizeof names[0], cmp_str);
    return n;
}

/* preset names as a JSON array, sorted */
static void print_presets(void)
{
    char *names[MAX_PRESETS];
    int n = list_presets(names);
    printf("[");
    for (int i = 0; i < n; i++) {
        printf("%s\"%s\"", i ? "," : "", names[i]);
        free(names[i]);
    }
    printf("]");
}

static void read_current(char *buf, size_t n)
{
    buf[0] = '\0';
    FILE *f = fopen(CURRENT_FILE, "r");
    if (f) {
        if (fgets(buf, (int)n, f))
            buf[strcspn(buf, "\n")] = '\0';
        fclose(f);
    }
    if (!valid_name(buf))
        buf[0] = '\0';
}

/* ------------------------------------------------------------------ panel: one button + the LCD
 * The "real pedal" front panel on the DE10-Standard: HPS_KEY cycles through the presets (in name
 * order, wrapping), the 128x64 LCD shows the preset's name, its number and the chain. Both hang off
 * the HPS: the button and the LCD's control lines are HPS GPIOs (sysfs), the LCD data goes through
 * SPI master 0, driven here through its registers (this kernel has no spidev).
 * The LCD is an ST7565-type controller; PANEL_FLIP=1 rotates it 180 degrees and PANEL_CONTRAST
 * (0..63) sets the contrast, in case a module differs. */

#define SPIM0_BASE 0xFFF00000u
#define GPIO1_LABEL "ff709000.gpio" /* HPS GPIO29..57 */
#define PIN_LCD_BK  (37 - 29)
#define PIN_LCD_DC  (41 - 29)
#define PIN_LCD_RST (44 - 29)
#define PIN_KEY     (54 - 29)

/* 5x7 glyphs, drawn for this project. Names are a-z0-9; they are shown in capitals. */
static const char *const FONT_CHARS = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ/>-+.:";
static const char FONT[][7][6] = {
    {"     ", "     ", "     ", "     ", "     ", "     ", "     "}, /* space */
    {" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "}, /* 0 */
    {"  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "}, /* 1 */
    {" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"}, /* 2 */
    {"#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### "}, /* 3 */
    {"   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "}, /* 4 */
    {"#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "}, /* 5 */
    {"  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### "}, /* 6 */
    {"#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "}, /* 7 */
    {" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "}, /* 8 */
    {" ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  "}, /* 9 */
    {" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"}, /* A */
    {"#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "}, /* B */
    {" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "}, /* C */
    {"#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### "}, /* D */
    {"#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"}, /* E */
    {"#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "}, /* F */
    {" ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ####"}, /* G */
    {"#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"}, /* H */
    {" ### ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "}, /* I */
    {"  ###", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  "}, /* J */
    {"#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"}, /* K */
    {"#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"}, /* L */
    {"#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #"}, /* M */
    {"#   #", "#   #", "##  #", "# # #", "#  ##", "#   #", "#   #"}, /* N */
    {" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "}, /* O */
    {"#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "}, /* P */
    {" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"}, /* Q */
    {"#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"}, /* R */
    {" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "}, /* S */
    {"#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "}, /* T */
    {"#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "}, /* U */
    {"#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "}, /* V */
    {"#   #", "#   #", "#   #", "# # #", "# # #", "# # #", " # # "}, /* W */
    {"#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"}, /* X */
    {"#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "}, /* Y */
    {"#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"}, /* Z */
    {"     ", "    #", "   # ", "  #  ", " #   ", "#    ", "     "}, /* / */
    {"     ", " #   ", "  #  ", "   # ", "  #  ", " #   ", "     "}, /* > */
    {"     ", "     ", "     ", "#####", "     ", "     ", "     "}, /* - */
    {"     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     "}, /* + */
    {"     ", "     ", "     ", "     ", "     ", " ##  ", " ##  "}, /* . */
    {"     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     "}, /* : */
};

static uint8_t fb[8][128]; /* 8 pages of 8 rows; bit 0 = top row of the page */

static void px(int x, int y)
{
    if (x >= 0 && x < 128 && y >= 0 && y < 64)
        fb[y / 8][x] |= (uint8_t)(1u << (y % 8));
}

/* text at (x, y) with each font pixel drawn s x s; returns the width drawn */
static int draw_text(int x, int y, const char *t, int s)
{
    int x0 = x;
    for (; *t; t++) {
        int c = *t >= 'a' && *t <= 'z' ? *t - 32 : *t;
        const char *pos = strchr(FONT_CHARS, c);
        int g = pos && c ? (int)(pos - FONT_CHARS) : 0;
        for (int r = 0; r < 7; r++)
            for (int col = 0; col < 5; col++)
                if (FONT[g][r][col] == '#')
                    for (int dy = 0; dy < s; dy++)
                        for (int dx = 0; dx < s; dx++)
                            px(x + col * s + dx, y + r * s + dy);
        x += 6 * s;
    }
    return x - x0 - s;
}

static int text_width(const char *t, int s) { return (int)strlen(t) * 6 * s - s; }

/* the screen: "PRESET n/N" and CAB/volume on top, the name as big as it fits, the chain at the bottom */
static void render(const char *name, int idx, int count, uint32_t chain, uint32_t cfg, uint32_t vol)
{
    static const char *abbr[N_FX] = {"BST", "DST", "OD", "TRM", "DLY", "WAH", "PHS", "REV", "CMP", "CHO", "FLG"};
    char line[64];
    memset(fb, 0, sizeof fb);

    if (count)
        snprintf(line, sizeof line, "PRESET %d/%d", idx + 1, count);
    else
        snprintf(line, sizeof line, "NO PRESETS");
    draw_text(0, 0, line, 1);
    snprintf(line, sizeof line, "%s%s", cfg & CFG_CAB ? "CAB " : "", vol == 0 ? "MUTE" : "");
    draw_text(128 - text_width(line, 1), 0, line, 1);
    for (int x = 0; x < 128; x++)
        px(x, 9);

    const char *big = name[0] ? name : (count ? "-" : "SAVE ONE");
    int s = 3;
    while (s > 1 && text_width(big, s) > 128)
        s--;
    char cut[22];
    snprintf(cut, sizeof cut, "%s", big); /* 21 characters fit at size 1 */
    draw_text((128 - text_width(cut, s)) / 2, 33 - 7 * s / 2, cut, s);

    line[0] = '\0';
    for (int slot = 0; slot < 8; slot++) {
        unsigned fx = (chain >> (4 * slot)) & 0xF;
        if (fx < N_FX)
            snprintf(line + strlen(line), sizeof line - strlen(line), "%s%s", line[0] ? ">" : "", abbr[fx]);
    }
    if (!line[0])
        snprintf(line, sizeof line, "CLEAN");
    line[21] = '\0';
    draw_text((128 - text_width(line, 1)) / 2, 57, line, 1);
}

/* host-side check of the screen layout: prints the framebuffer as text */
static void print_fb(void)
{
    for (int y = 0; y < 64; y++) {
        for (int x = 0; x < 128; x++)
            putchar(fb[y / 8][x] & (1u << (y % 8)) ? '#' : '.');
        putchar('\n');
    }
}

static int gpio_base(void)
{
    DIR *d = opendir("/sys/class/gpio");
    struct dirent *e;
    int base = -1;
    while (d && (e = readdir(d))) {
        char path[300], buf[64] = "";
        if (strncmp(e->d_name, "gpiochip", 8))
            continue;
        snprintf(path, sizeof path, "/sys/class/gpio/%s/label", e->d_name);
        FILE *f = fopen(path, "r");
        if (f && fgets(buf, sizeof buf, f) && strncmp(buf, GPIO1_LABEL, strlen(GPIO1_LABEL)) == 0)
            base = atoi(e->d_name + 8);
        if (f)
            fclose(f);
    }
    if (d)
        closedir(d);
    return base;
}

static void write_file(const char *path, const char *v)
{
    FILE *f = fopen(path, "w");
    if (f) {
        fputs(v, f);
        fclose(f);
    }
}

/* export an HPS GPIO1 pin; returns an open fd on its value file */
static int gpio_open(int base, int pin, const char *dir)
{
    char path[64], num[16];
    snprintf(num, sizeof num, "%d", base + pin);
    snprintf(path, sizeof path, "/sys/class/gpio/gpio%d/direction", base + pin);
    if (access(path, F_OK))
        write_file("/sys/class/gpio/export", num);
    write_file(path, dir);
    snprintf(path, sizeof path, "/sys/class/gpio/gpio%d/value", base + pin);
    return open(path, O_RDWR);
}

static void gpio_set(int fd, int v) { (void)!pwrite(fd, v ? "1" : "0", 1, 0); }

static int gpio_get(int fd)
{
    char c = '1';
    (void)!pread(fd, &c, 1, 0);
    return c == '1';
}

static void sleep_ms(int ms)
{
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000L};
    nanosleep(&t, NULL);
}

/* SPI master 0 (DesignWare SSI): mode 3, 8-bit frames, transmit only */
enum { SPI_CTRLR0 = 0x00, SPI_SSIENR = 0x08, SPI_SER = 0x10, SPI_BAUDR = 0x14, SPI_SR = 0x28, SPI_DR = 0x60 };
static volatile uint32_t *spi;
static int fd_dc;

static void spi_init(void)
{
    spi[SPI_SSIENR / 4] = 0;
    spi[SPI_CTRLR0 / 4] = (1u << 8) | (1u << 7) | (1u << 6) | 7; /* TMOD tx-only, SCPOL, SCPH, 8 bits */
    spi[SPI_BAUDR / 4] = 64;                                    /* spi_m_clk / 64: a few MHz */
    spi[SPI_SER / 4] = 1;
    spi[SPI_SSIENR / 4] = 1;
}

static void spi_send(int dc, const uint8_t *b, int n)
{
    while ((spi[SPI_SR / 4] & 5) != 4) /* wait: TX FIFO empty and not busy, before switching D/C */
        ;
    gpio_set(fd_dc, dc);
    for (int i = 0; i < n; i++) {
        while (!(spi[SPI_SR / 4] & 2)) /* TX FIFO not full */
            ;
        spi[SPI_DR / 4] = b[i];
    }
    while ((spi[SPI_SR / 4] & 5) != 4)
        ;
}

static void lcd_flush(int flip)
{
    for (int p = 0; p < 8; p++) {
        int col = flip ? 4 : 0; /* the controller has 132 columns; rotated, the visible ones start at 4 */
        uint8_t c[3] = {(uint8_t)(0xB0 | p), (uint8_t)(0x10 | (col >> 4)), (uint8_t)(col & 0xF)};
        spi_send(0, c, 3);
        spi_send(1, fb[p], 128);
    }
}

static int panel(volatile uint32_t *regs)
{
    int base = gpio_base();
    if (base < 0) {
        fprintf(stderr, "no %s in /sys/class/gpio\n", GPIO1_LABEL);
        return 1;
    }
    int fd_bk = gpio_open(base, PIN_LCD_BK, "out"), fd_rst = gpio_open(base, PIN_LCD_RST, "out");
    int fd_key = gpio_open(base, PIN_KEY, "in");
    fd_dc = gpio_open(base, PIN_LCD_DC, "out");
    if (fd_bk < 0 || fd_rst < 0 || fd_key < 0 || fd_dc < 0) {
        perror("gpio");
        return 1;
    }
    int mfd = open("/dev/mem", O_RDWR | O_SYNC);
    spi = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, SPIM0_BASE);
    close(mfd);
    if (spi == MAP_FAILED) {
        perror("mmap spi");
        return 1;
    }
    const char *e = getenv("PANEL_FLIP");
    int flip = e && atoi(e);
    e = getenv("PANEL_CONTRAST");
    int contrast = e ? atoi(e) & 63 : 24;

    spi_init();
    gpio_set(fd_bk, 1);
    gpio_set(fd_rst, 0);
    sleep_ms(5);
    gpio_set(fd_rst, 1);
    sleep_ms(5);
    uint8_t init[] = {0xA2,                    /* bias 1/9 */
                      (uint8_t)(flip ? 0xA1 : 0xA0), (uint8_t)(flip ? 0xC0 : 0xC8), /* orientation */
                      0x40,                    /* start line 0 */
                      0x2F,                    /* booster, regulator, follower on */
                      0x26,                    /* regulator resistor ratio */
                      0x81, (uint8_t)contrast, /* contrast */
                      0xA6, 0xA4, 0xAF};       /* normal, from RAM, display on */
    spi_send(0, init, sizeof init);

    /* back to the preset in use at power-off */
    char cur[32], shown[32] = "?";
    read_current(cur, sizeof cur);
    if (cur[0])
        preset_load(regs, cur);

    int idle = gpio_get(fd_key), was = 0, stable = 0, last_sig = -1;
    for (int tick = 0;; tick++) {
        /* button: debounced over 3 reads (30 ms); acts on press */
        int now = gpio_get(fd_key) != idle;
        stable = now == was ? stable + 1 : 0;
        was = now;
        int pressed = now && stable == 2;

        char *names[MAX_PRESETS];
        int n = 0, idx = -1;
        if (pressed || tick % 25 == 0) { /* the web UI may change things: re-check every 250 ms */
            n = list_presets(names);
            read_current(cur, sizeof cur);
            for (int i = 0; i < n; i++)
                if (strcmp(names[i], cur) == 0)
                    idx = i;
            if (pressed && n) {
                idx = (idx + 1) % n;
                preset_load(regs, names[idx]);
                snprintf(cur, sizeof cur, "%s", names[idx]);
            }
            uint32_t chain = regs[REG_CHAIN], cfg = regs[REG_CONFIG], vol = regs[REG_VOLUME] & 31;
            int sig = (int)(chain ^ (cfg << 3) ^ (vol << 7) ^ ((uint32_t)idx << 13) ^ ((uint32_t)n << 21));
            if (pressed || sig != last_sig || strcmp(shown, cur)) {
                render(idx >= 0 ? cur : "", idx, n, chain, cfg, vol);
                lcd_flush(flip);
                last_sig = sig;
                snprintf(shown, sizeof shown, "%s", cur);
            }
            for (int i = 0; i < n; i++)
                free(names[i]);
        }
        sleep_ms(10);
    }
}

/* ------------------------------------------------------------------ main */

int main(int argc, char **argv)
{
    if (argc < 2)
        return usage();
    const char *cmd = argv[1];
    if (strcmp(cmd, "pitchtest") == 0)
        return pitchtest();
    if (strcmp(cmd, "paneltest") == 0) { /* the LCD screen for a sample preset, as text */
        render("crunchlead", 2, 7, 0xFFFFF7A2u, CFG_CAB, 31);
        print_fb();
        return 0;
    }

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
    } else if (strcmp(cmd, "panel") == 0) {
        ret = panel(regs);
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
