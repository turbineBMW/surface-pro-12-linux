/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2020 - 2025 Intel Corporation
 *
 * PSYS subsystem config, as in ipu7-drivers' abi/ipu7_fw_psys_config_abi.h,
 * using the in-tree ipu6 driver's names for the logger and watchdog config
 * (ipu7-boot.h) instead of abi/ipu7_fw_boot_abi.h.
 */
#ifndef IPU7_PSYS_CONFIG_ABI_H_INCLUDED__
#define IPU7_PSYS_CONFIG_ABI_H_INCLUDED__

#include <linux/types.h>

#include "ipu6-bus.h"
#include "ipu7-boot.h"

struct ipu7_psys_config {
	u32 use_debug_manifest;
	u32 timeout_val_ms;
	u32 compression_support_enabled;
	struct ipu7_fw_logger_config logger_config;
	struct ipu7_wdt_abi wdt_config;
	u8 ipu_psys_debug_bitmask;
	u8 padding[3];
};

#endif
