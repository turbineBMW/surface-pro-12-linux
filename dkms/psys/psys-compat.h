/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Definitions Intel's out-of-tree IPU7 PSYS driver takes from its own
 * ipu7 core headers, for building it on the in-tree ipu6 core (7.4+),
 * which drives IPU7 and creates the psys auxiliary device but has no
 * PSYS driver.
 */
#ifndef PSYS_COMPAT_H
#define PSYS_COMPAT_H

#include "ipu6.h"
#include "ipu6-bus.h"
#include "ipu7-platform-regs.h"
#include "ipu7-boot.h"

#define IPU_NAME			"intel-ipu7"
#define IPU_PSYS_NAME			IPU6_PSYS_NAME

#define IPU_PSYS_CMD_TIMEOUT_MS		2000
#define IPU_PSYS_OPEN_CLOSE_TIMEOUT_US	50
#define IPU_PSYS_OPEN_CLOSE_RETRY	(10000 / IPU_PSYS_OPEN_CLOSE_TIMEOUT_US)

/* PSYS to SW interrupt controller (ipu7-platform-regs.h in ipu7-drivers) */
#define IPU_REG_PSYS_TO_SW_IRQ_CNTL_EDGE		0x134000
#define IPU_REG_PSYS_TO_SW_IRQ_CNTL_MASK		0x134004
#define IPU_REG_PSYS_TO_SW_IRQ_CNTL_STATUS		0x134008
#define IPU_REG_PSYS_TO_SW_IRQ_CNTL_CLEAR		0x13400c
#define IPU_REG_PSYS_TO_SW_IRQ_CNTL_ENABLE		0x134010
#define IPU_REG_PSYS_TO_SW_IRQ_CNTL_LEVEL_NOT_PULSE	0x134014
#define IRQ_FROM_LOCAL_FW				BIT(0)

#define FW_LOG_BUF_SIZE			(2 * 1024 * 1024)

/* abi/ipu7_fw_boot_abi.h in ipu7-drivers; ipu7-boot.h here */
#define IA_GOFO_FW_BOOT_STATE_IS_CRITICAL(s)	IPU7_BOOT_STATE_CRITICAL(s)

/* ipu7-boot.h in ipu7-drivers */
#define FW_QUEUE_CONFIG_SIZE(num_queues)	\
	(sizeof(struct ipu7_fw_com_queue_config) * (num_queues))

#endif
