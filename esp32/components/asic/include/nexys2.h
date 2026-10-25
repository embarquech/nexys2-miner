#ifndef NEXYS2_H_
#define NEXYS2_H_

#include <stdbool.h>
#include "asic_common.h"

typedef struct GlobalState GlobalState;
typedef struct bm_job bm_job;

// Digilent Nexys2 running the nexys2-miner FPGA bitstream (SHA-256d units),
// reached over UART1; protocol in nexys2-miner/hdl/uart_bridge.vhd.
#define NEXYS2_BAUD 921600
// Clock cycles one FPGA unit spends per nonce (hdl/miner_unit.vhd).
#define NEXYS2_CYCLES_PER_NONCE 122

uint8_t NEXYS2_init(GlobalState * GLOBAL_STATE);
int NEXYS2_set_max_baud(void);
void NEXYS2_send_work(GlobalState * GLOBAL_STATE, bm_job * next_bm_job);
task_result * NEXYS2_process_work(GlobalState * GLOBAL_STATE);
void NEXYS2_read_registers(GlobalState * GLOBAL_STATE);
void NEXYS2_set_lights(bool on);

#endif /* NEXYS2_H_ */
