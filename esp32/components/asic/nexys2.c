#include "nexys2.h"

#include "global_state.h"
#include "hashrate_monitor_task.h"
#include "mining.h"
#include "nvs_config.h"
#include "serial.h"
#include "utils.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include <inttypes.h>
#include <stdint.h>
#include <string.h>

static const char *TAG = "nexys2";
static bool short_job;            // the bitstream takes the 76-byte job

// FPGA register map (nexys2-miner/hdl/miner_top.vhd)
#define REG_JOB      0x00     // job port: midstate, tail, [first, mask,] state3
#define REG_CTRL     0x38
#define REG_STATUS   0x39
#define REG_CLEAR    0x3A
#define REG_LIGHTS   0x3B
#define REG_FOUND    0x40
#define REG_PROGRESS 0x44
#define REG_STRIDE   0x4D     // nonce stride (0 on older bitstreams: = units)
#define REG_MAGIC    0x4E
#define MAGIC        0xB7     // 84-byte job (first nonce word and hit mask)
#define MAGIC_SHORT  0xB8     // 76-byte job: nonce 0 and 20-bit mask built in

#define CMD_WRITE 0x57
#define CMD_JOB   0x4A           // write n bytes to one address
#define CMD_READ  0x52
#define ACK       0x06
#define UART_TIMEOUT_MS 50

// The FPGA flags hashes whose top FPGA_HIT_BITS bits are zero (fixed in the
// UART bitstream, ~3 hits/s). Every one is re-hashed here, which keeps a
// running count of wrong hashes (an overclock that has gone too far), and only
// those with HIT_BITS or more go on to ESP-Miner: at 24, one every ~5 s at
// 3.4 MH/s, enough to fill the Shares page without flooding it.
#define FPGA_HIT_BITS 20
#ifndef HIT_BITS
#define HIT_BITS 24
#endif

#define POLL_MS 20

static SemaphoreHandle_t fpga_lock;
static uint8_t ncores;
static uint8_t stride;            // unit i hashes nonce words i, i + stride, ...
static int baud = NEXYS2_BAUD;    // the FPGA's actual baud rate, see find_fpga()
static uint8_t job_id;
static uint32_t job_version;
static bool job_loaded;
static int64_t job_loaded_us;
static uint32_t last_progress;
static int64_t last_progress_us;
static uint32_t last_job_seq, job_seq;
static uint8_t job_header[80];           // header of the loaded job, nonce bytes left 0
static uint32_t hits_good, hits_bad;
static task_result result;

// --------------------------------------------------------------------------
// UART register access. Callers hold fpga_lock.
// --------------------------------------------------------------------------

static bool fpga_cmd_write(uint8_t cmd, uint8_t addr, const uint8_t *data, uint8_t n)
{
    uint8_t buf[3 + 255];
    buf[0] = cmd;
    buf[1] = addr;
    buf[2] = n;
    memcpy(buf + 3, data, n);
    SERIAL_send(buf, 3 + n, false);
    uint8_t ack = 0;
    if (SERIAL_rx(&ack, 1, UART_TIMEOUT_MS) != 1 || ack != ACK) {
        ESP_LOGW(TAG, "no ack for write at 0x%02X", addr);
        return false;
    }
    return true;
}

static bool fpga_write(uint8_t addr, const uint8_t *data, uint8_t n)
{
    return fpga_cmd_write(CMD_WRITE, addr, data, n);
}

static bool fpga_write_byte(uint8_t addr, uint8_t value)
{
    return fpga_write(addr, &value, 1);
}

static bool fpga_read(uint8_t addr, uint8_t *data, uint8_t n)
{
    uint8_t cmd[3] = {CMD_READ, addr, n};
    SERIAL_send(cmd, 3, false);
    if (SERIAL_rx(data, n, UART_TIMEOUT_MS) != n) {
        ESP_LOGW(TAG, "short read at 0x%02X", addr);
        SERIAL_clear_buffer();
        return false;
    }
    return true;
}

static uint32_t be32(const uint8_t *b)
{
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}

static void put_be32(uint8_t *b, uint32_t v)
{
    b[0] = v >> 24;
    b[1] = v >> 16;
    b[2] = v >> 8;
    b[3] = v;
}

// --------------------------------------------------------------------------
// SHA-256 compression, for a midstate in the FPGA's word order (H0 first,
// big-endian words) independent of the BM job packet conventions.
// --------------------------------------------------------------------------

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_midstate(const uint8_t block[64], uint32_t state[8])
{
    static const uint32_t IV[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    uint32_t w[64];
    for (int t = 0; t < 16; t++) {
        w[t] = be32(block + 4 * t);
    }
    for (int t = 16; t < 64; t++) {
        uint32_t s0 = ROTR(w[t - 15], 7) ^ ROTR(w[t - 15], 18) ^ (w[t - 15] >> 3);
        uint32_t s1 = ROTR(w[t - 2], 17) ^ ROTR(w[t - 2], 19) ^ (w[t - 2] >> 10);
        w[t] = w[t - 16] + s0 + w[t - 7] + s1;
    }
    uint32_t a = IV[0], b = IV[1], c = IV[2], d = IV[3], e = IV[4], f = IV[5], g = IV[6], h = IV[7];
    for (int t = 0; t < 64; t++) {
        uint32_t t1 = h + (ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25)) + ((e & f) ^ (~e & g)) + K[t] + w[t];
        uint32_t t2 = (ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    state[0] = IV[0] + a; state[1] = IV[1] + b; state[2] = IV[2] + c; state[3] = IV[3] + d;
    state[4] = IV[4] + e; state[5] = IV[5] + f; state[6] = IV[6] + g; state[7] = IV[7] + h;
}

// a..h of the second block after rounds 0-2. Those rounds only use header
// bytes 64..75 (W0-W2), the same for every nonce, so the FPGA starts at round 3.
static void sha256_state3(const uint32_t mid[8], const uint8_t tail[12], uint32_t out[8])
{
    uint32_t a = mid[0], b = mid[1], c = mid[2], d = mid[3], e = mid[4], f = mid[5], g = mid[6], h = mid[7];
    for (int t = 0; t < 3; t++) {
        uint32_t t1 = h + (ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25)) + ((e & f) ^ (~e & g)) + K[t] + be32(tail + 4 * t);
        uint32_t t2 = (ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    out[0] = a; out[1] = b; out[2] = c; out[3] = d; out[4] = e; out[5] = f; out[6] = g; out[7] = h;
}

// --------------------------------------------------------------------------
// ASIC driver interface
// --------------------------------------------------------------------------

// Read the magic at the current baud rate, GPIO17 TX / GPIO18 RX first, then
// swapped. Caller holds fpga_lock.
static bool probe_pins(uint8_t id[2])
{
    SERIAL_clear_buffer();
    // Bytes other than a command are ignored, so this ends any half-sent command.
    uint8_t idle[4] = {0xFF, 0xFF, 0xFF, 0xFF};
    SERIAL_send(idle, sizeof(idle), false);
    vTaskDelay(pdMS_TO_TICKS(10));
    SERIAL_clear_buffer();
    if (fpga_read(REG_MAGIC, id, 2) && (id[0] == MAGIC || id[0] == MAGIC_SHORT)) {
        return true;
    }
    // TX and RX crossed the wrong way round is the usual wiring slip; the
    // pins are only a mux setting on the ESP32, so try them swapped.
    // Detach both first: uart_set_pin() leaves GPIO17 routed to TX as
    // well, which would drive against the FPGA's TX and echo our bytes.
    gpio_reset_pin(17);
    gpio_reset_pin(18);
    uart_set_pin(UART_NUM_1, 18, 17, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    vTaskDelay(pdMS_TO_TICKS(10));
    SERIAL_clear_buffer();
    if (fpga_read(REG_MAGIC, id, 2) && (id[0] == MAGIC || id[0] == MAGIC_SHORT)) {
        ESP_LOGW(TAG, "found with GPIO18 TX / GPIO17 RX: the wires are crossed, it works anyway");
        return true;
    }
    gpio_reset_pin(17);
    gpio_reset_pin(18);
    uart_set_pin(UART_NUM_1, 17, 18, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    return false;
}

// The FPGA's UART divider is fixed for the clock the bitstream was built for
// (103.3 MHz). A bitstream re-clocked through its DCM (ise/refreq.sh) keeps
// that divider, so its baud rate scales with the clock: if 921600 gets no
// answer, try the rates of other clocks, 1 MHz apart (a UART tolerates ~3 %).
static bool find_fpga(uint8_t id[2])
{
    baud = NEXYS2_BAUD;
    SERIAL_set_baud(baud);
    if (probe_pins(id)) {
        return true;
    }
    ESP_LOGW(TAG, "no answer at %d baud, scanning for a re-clocked bitstream", baud);
    for (int mhz = 110; mhz >= 50; mhz--) {
        int b = (int)((int64_t)NEXYS2_BAUD * mhz * 3 / 310);   // built for 310/3 MHz
        if (mhz == 103) {
            continue;
        }
        SERIAL_set_baud(b);
        if (probe_pins(id)) {
            baud = b;
            ESP_LOGW(TAG, "found at %d baud: FPGA clock about %d MHz", b, mhz);
            return true;
        }
    }
    baud = NEXYS2_BAUD;
    SERIAL_set_baud(baud);
    return false;
}

uint8_t NEXYS2_init(GlobalState * GLOBAL_STATE)
{
    if (fpga_lock == NULL) {
        fpga_lock = xSemaphoreCreateMutex();
    }

    uint8_t id[2] = {0};
    xSemaphoreTake(fpga_lock, portMAX_DELAY);
    bool ok = find_fpga(id);
    xSemaphoreGive(fpga_lock);
    if (!ok) {
        ESP_LOGE(TAG, "Nexys2 not found on UART1 (read %02X %02X): check the UART bitstream and wiring", id[0], id[1]);
        return 0;
    }
    ncores = id[1];
    // 5 units step by 8 (the unit number sits in the low bits), so the nonce
    // counter and the unit count no longer match
    uint8_t st = 0;
    xSemaphoreTake(fpga_lock, portMAX_DELAY);
    bool st_ok = fpga_read(REG_STRIDE, &st, 1);
    xSemaphoreGive(fpga_lock);
    stride = (st_ok && st >= ncores) ? st : ncores;
    GLOBAL_STATE->DEVICE_CONFIG.family.asic.core_count = ncores;
    GLOBAL_STATE->DEVICE_CONFIG.family.asic.small_core_count = ncores;
    // The power task computed this with the default unit count, before the
    // FPGA was found; GH/s
    GLOBAL_STATE->POWER_MANAGEMENT_MODULE.expected_hashrate =
        GLOBAL_STATE->POWER_MANAGEMENT_MODULE.frequency_value * ncores / NEXYS2_CYCLES_PER_NONCE / 1000.0;
    short_job = id[0] == MAGIC_SHORT;
    ESP_LOGI(TAG, "Nexys2 FPGA miner found, %u hashing units, nonce stride %u", ncores, stride);

    NEXYS2_set_lights(!nvs_config_get_bool(NVS_CONFIG_FPGA_LIGHTS_OFF));

    GLOBAL_STATE->POWER_MANAGEMENT_MODULE.actual_frequency = GLOBAL_STATE->POWER_MANAGEMENT_MODULE.frequency_value;
    return 1;
}

int NEXYS2_set_max_baud(void)
{
    return baud;
}

void NEXYS2_set_lights(bool on)
{
    if (fpga_lock == NULL) {
        return;
    }
    xSemaphoreTake(fpga_lock, portMAX_DELAY);
    fpga_write_byte(REG_LIGHTS, on ? 0x00 : 0x01);
    xSemaphoreGive(fpga_lock);
}

void NEXYS2_send_work(GlobalState * GLOBAL_STATE, bm_job * next_bm_job)
{
    // Same 80-byte header test_nonce_value_full() rebuilds for verification.
    uint8_t header[80];
    memcpy(header, &next_bm_job->version, 4);
    reverse_32bit_words(next_bm_job->prev_block_hash, header + 4);
    reverse_32bit_words(next_bm_job->merkle_root, header + 36);
    memcpy(header + 68, &next_bm_job->ntime, 4);
    memcpy(header + 72, &next_bm_job->target, 4);

    uint32_t mid[8];
    sha256_midstate(header, mid);

    // job port: midstate, header bytes 64..75, first nonce word and hit mask
    // (long job only), state3
    uint8_t regs[84];
    size_t len = 0;
    for (int i = 0; i < 8; i++) {
        put_be32(regs + 4 * i, mid[i]);
    }
    memcpy(regs + 32, header + 64, 12);
    len = 44;
    if (!short_job) {
        put_be32(regs + 44, 0);
        // The hash is read little-endian, so its top 32 bits are H7 byte-swapped.
        uint32_t top = (uint32_t)(((1ULL << FPGA_HIT_BITS) - 1) << (32 - FPGA_HIT_BITS));
        put_be32(regs + 48, __builtin_bswap32(top));
        len = 52;
    }

    uint32_t st3[8];
    sha256_state3(mid, header + 64, st3);
    for (int i = 0; i < 8; i++) {
        put_be32(regs + len + 4 * i, st3[i]);
    }
    len += 32;

    uint8_t id = (job_id + 4) % 128;      // multiples of 4, as SYSTEM_clean_jobs_queue expects

    pthread_mutex_lock(&GLOBAL_STATE->valid_jobs_lock);
    if (GLOBAL_STATE->ASIC_TASK_MODULE.active_jobs[id] != NULL) {
        free_bm_job(GLOBAL_STATE->ASIC_TASK_MODULE.active_jobs[id]);
    }
    GLOBAL_STATE->ASIC_TASK_MODULE.active_jobs[id] = next_bm_job;
    GLOBAL_STATE->valid_jobs[id] = 1;
    pthread_mutex_unlock(&GLOBAL_STATE->valid_jobs_lock);

    xSemaphoreTake(fpga_lock, portMAX_DELAY);
    bool ok = fpga_write_byte(REG_CTRL, 0x02)            // stop
              && fpga_cmd_write(CMD_JOB, REG_JOB, regs, len)
              && fpga_write_byte(REG_CTRL, 0x01);       // restart from nonce word 0
    if (ok) {
        // A hit read after this point belongs to the new job: restart clears it.
        job_id = id;
        job_version = next_bm_job->version;
        job_loaded = true;
        job_loaded_us = esp_timer_get_time();
        job_seq++;
        memcpy(job_header, header, sizeof(job_header));
    }
    xSemaphoreGive(fpga_lock);

    if (!ok) {
        ESP_LOGE(TAG, "failed to load job %02X into the FPGA", id);
    }
}

task_result * NEXYS2_process_work(GlobalState * GLOBAL_STATE)
{
    // Block for up to a second: the result task loops on this without delay,
    // so returning at once would spin it into the task watchdog.
    for (int i = 0; i < 1000 / POLL_MS; i++) {
        uint8_t status = 0, word[4];
        bool hit = false;
        uint8_t hit_job = 0;
        uint32_t hit_version = 0;
        uint8_t hit_header[80];

        xSemaphoreTake(fpga_lock, portMAX_DELAY);
        if (job_loaded && fpga_read(REG_STATUS, &status, 1) && (status & 0x02)) {
            if (fpga_read(REG_FOUND, word, 4)) {
                fpga_write_byte(REG_CLEAR, 0x00);
                hit = true;
                hit_job = job_id;
                hit_version = job_version;
                memcpy(hit_header, job_header, sizeof(hit_header));
            }
        }
        xSemaphoreGive(fpga_lock);

        if (hit) {
            // the FPGA reports the unit's counter, already one step past the hit
            uint32_t w = be32(word) - stride;
            put_be32(word, w);

            // Re-hash: an overclocked FPGA can return wrong nonces, and the
            // good/bad tally is the only way to see that from here.
            uint8_t hash[32];
            memcpy(hit_header + 76, word, 4);
            double_sha256_bin(hit_header, 80, hash);
            // hash is little-endian: its top bits are the last bytes
            uint32_t top32 = ((uint32_t)hash[31] << 24) | ((uint32_t)hash[30] << 16) | ((uint32_t)hash[29] << 8) | hash[28];
            bool good = (top32 >> (32 - FPGA_HIT_BITS)) == 0;
            if (good) {
                hits_good++;
            } else {
                hits_bad++;
            }
            if ((hits_good + hits_bad) % 1000 == 0) {
                ESP_LOGI(TAG, "hits checked: %" PRIu32 " good, %" PRIu32 " bad (%.1f%% bad)",
                         hits_good, hits_bad, 100.0 * hits_bad / (hits_good + hits_bad));
            }
            if (!good) {
                ESP_LOGW(TAG, "bad hit 0x%08" PRIX32 " from unit %d: the FPGA clock may be too fast",
                         w, stride ? (int)(w % stride) : 0);
                vTaskDelay(pdMS_TO_TICKS(POLL_MS));
                continue;
            }
            if ((top32 >> (32 - HIT_BITS)) != 0) {
                continue;                     // good, but below what ESP-Miner wants
            }
            memset(&result, 0, sizeof(result));
            result.job_id = hit_job;
            // header bytes 76..79 are the word big-endian; the nonce is their
            // little-endian value (test_nonce_value_full memcpy's it in place)
            result.nonce = __builtin_bswap32(w);
            result.rolled_version = hit_version;    // the FPGA does not roll versions
            result.asic_nr = 0;
            result.core_id = stride ? w % stride : 0; // unit i hashes words i, i + stride, ...
            result.timestamp_us = esp_timer_get_time();
            return &result;
        }
        vTaskDelay(pdMS_TO_TICKS(POLL_MS));
    }
    return NULL;
}

void NEXYS2_read_registers(GlobalState * GLOBAL_STATE)
{
    uint8_t word[4];
    xSemaphoreTake(fpga_lock, portMAX_DELAY);
    bool ok = job_loaded && fpga_read(REG_PROGRESS, word, 4);
    uint32_t seq = job_seq;
    int64_t loaded_us = job_loaded_us;
    xSemaphoreGive(fpga_lock);
    if (!ok) {
        return;
    }

    // Unit 0's nonce word advances by the stride each time every unit
    // finishes a nonce: ncores nonces hashed per stride.
    uint32_t progress = be32(word);
    int64_t now = esp_timer_get_time();
    uint32_t hashes;
    int64_t elapsed;
    if (seq != last_job_seq) {                // a job reload restarted the count at 0
        hashes = progress;
        elapsed = now - loaded_us;
        last_job_seq = seq;
    } else {
        hashes = progress - last_progress;
        elapsed = now - last_progress_us;
    }
    last_progress = progress;
    last_progress_us = now;
    if (elapsed <= 0) {
        return;
    }

    uint32_t hps = (uint32_t)((uint64_t)hashes * ncores * 1000000ULL / ((uint64_t)elapsed * (stride ? stride : 1)));
    hashrate_monitor_register_read(GLOBAL_STATE, REGISTER_HASHRATE_HPS, 0, hps, now);
}
