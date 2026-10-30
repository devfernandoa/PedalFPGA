// PedalFPGA top level (DE10-Standard): the HPS system (soc_system, from make_soc_system.tcl) and the
// audio pedal (pedal_core). Only the pins the design uses are ports; the rest of the board is left
// unconnected (Quartus reserves unused pins as inputs).
module PedalFPGA_top (
    input         CLOCK_50,

    output [9:0]  LEDR,
    output [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,

    // WM8731 codec (it drives BCLK and the LR clocks)
    input         AUD_BCLK,
    input         AUD_ADCLRCK,
    input         AUD_DACLRCK,
    input         AUD_ADCDAT,
    output        AUD_DACDAT,
    output        AUD_XCK,
    output        FPGA_I2C_SCLK,
    inout         FPGA_I2C_SDAT,
    output        TD_RESET_N,      // video decoder: shares the I2C bus with the codec, kept in reset

    // HPS: DDR3
    output [14:0] HPS_DDR3_ADDR,
    output [2:0]  HPS_DDR3_BA,
    output        HPS_DDR3_CAS_N, HPS_DDR3_RAS_N, HPS_DDR3_WE_N,
    output        HPS_DDR3_CKE, HPS_DDR3_CK_N, HPS_DDR3_CK_P, HPS_DDR3_CS_N,
    output        HPS_DDR3_ODT, HPS_DDR3_RESET_N,
    output [3:0]  HPS_DDR3_DM,
    inout  [31:0] HPS_DDR3_DQ,
    inout  [3:0]  HPS_DDR3_DQS_N, HPS_DDR3_DQS_P,
    input         HPS_DDR3_RZQ,
    // HPS: Ethernet
    output        HPS_ENET_GTX_CLK, HPS_ENET_MDC, HPS_ENET_TX_EN,
    inout         HPS_ENET_INT_N, HPS_ENET_MDIO,
    input         HPS_ENET_RX_CLK, HPS_ENET_RX_DV,
    input  [3:0]  HPS_ENET_RX_DATA,
    output [3:0]  HPS_ENET_TX_DATA,
    // HPS: QSPI flash, SD card, USB, UART
    inout  [3:0]  HPS_FLASH_DATA,
    output        HPS_FLASH_DCLK, HPS_FLASH_NCSO,
    output        HPS_SD_CLK,
    inout         HPS_SD_CMD,
    inout  [3:0]  HPS_SD_DATA,
    input         HPS_USB_CLKOUT, HPS_USB_DIR, HPS_USB_NXT,
    inout  [7:0]  HPS_USB_DATA,
    output        HPS_USB_STP,
    input         HPS_UART_RX,
    output        HPS_UART_TX,
    // HPS: SPI (LCD and header), I2C, GPIO
    output        HPS_LCM_SPIM_CLK, HPS_LCM_SPIM_MOSI, HPS_LCM_SPIM_SS,
    input         HPS_LCM_SPIM_MISO,
    output        HPS_SPIM_CLK, HPS_SPIM_MOSI,
    input         HPS_SPIM_MISO,
    inout         HPS_SPIM_SS,
    inout         HPS_I2C1_SCLK, HPS_I2C1_SDAT, HPS_I2C2_SCLK, HPS_I2C2_SDAT,
    inout         HPS_CONV_USB_N, HPS_LCM_BK, HPS_LTC_GPIO, HPS_LCM_D_C, HPS_LCM_RST_N,
    inout         HPS_I2C_CONTROL, HPS_LED, HPS_KEY, HPS_GSENSOR_INT
);

    assign TD_RESET_N = 1'b0;

    wire [31:0] pedal_chain;
    wire [79:0] pedal_params;

    // The HPS I/O must all stay connected: the preloader on the SD card configures every one of them.
    soc_system u0 (
        .clk_clk        (CLOCK_50),
        .reset_reset_n  (1'b1),
        .pedal_chain    (pedal_chain),
        .pedal_params   (pedal_params),

        .memory_mem_a       (HPS_DDR3_ADDR),
        .memory_mem_ba      (HPS_DDR3_BA),
        .memory_mem_ck      (HPS_DDR3_CK_P),
        .memory_mem_ck_n    (HPS_DDR3_CK_N),
        .memory_mem_cke     (HPS_DDR3_CKE),
        .memory_mem_cs_n    (HPS_DDR3_CS_N),
        .memory_mem_ras_n   (HPS_DDR3_RAS_N),
        .memory_mem_cas_n   (HPS_DDR3_CAS_N),
        .memory_mem_we_n    (HPS_DDR3_WE_N),
        .memory_mem_reset_n (HPS_DDR3_RESET_N),
        .memory_mem_dq      (HPS_DDR3_DQ),
        .memory_mem_dqs     (HPS_DDR3_DQS_P),
        .memory_mem_dqs_n   (HPS_DDR3_DQS_N),
        .memory_mem_odt     (HPS_DDR3_ODT),
        .memory_mem_dm      (HPS_DDR3_DM),
        .memory_oct_rzqin   (HPS_DDR3_RZQ),

        .hps_0_hps_io_hps_io_emac1_inst_TX_CLK (HPS_ENET_GTX_CLK),
        .hps_0_hps_io_hps_io_emac1_inst_TX_CTL (HPS_ENET_TX_EN),
        .hps_0_hps_io_hps_io_emac1_inst_TXD0   (HPS_ENET_TX_DATA[0]),
        .hps_0_hps_io_hps_io_emac1_inst_TXD1   (HPS_ENET_TX_DATA[1]),
        .hps_0_hps_io_hps_io_emac1_inst_TXD2   (HPS_ENET_TX_DATA[2]),
        .hps_0_hps_io_hps_io_emac1_inst_TXD3   (HPS_ENET_TX_DATA[3]),
        .hps_0_hps_io_hps_io_emac1_inst_RX_CLK (HPS_ENET_RX_CLK),
        .hps_0_hps_io_hps_io_emac1_inst_RX_CTL (HPS_ENET_RX_DV),
        .hps_0_hps_io_hps_io_emac1_inst_RXD0   (HPS_ENET_RX_DATA[0]),
        .hps_0_hps_io_hps_io_emac1_inst_RXD1   (HPS_ENET_RX_DATA[1]),
        .hps_0_hps_io_hps_io_emac1_inst_RXD2   (HPS_ENET_RX_DATA[2]),
        .hps_0_hps_io_hps_io_emac1_inst_RXD3   (HPS_ENET_RX_DATA[3]),
        .hps_0_hps_io_hps_io_emac1_inst_MDIO   (HPS_ENET_MDIO),
        .hps_0_hps_io_hps_io_emac1_inst_MDC    (HPS_ENET_MDC),

        .hps_0_hps_io_hps_io_qspi_inst_IO0 (HPS_FLASH_DATA[0]),
        .hps_0_hps_io_hps_io_qspi_inst_IO1 (HPS_FLASH_DATA[1]),
        .hps_0_hps_io_hps_io_qspi_inst_IO2 (HPS_FLASH_DATA[2]),
        .hps_0_hps_io_hps_io_qspi_inst_IO3 (HPS_FLASH_DATA[3]),
        .hps_0_hps_io_hps_io_qspi_inst_SS0 (HPS_FLASH_NCSO),
        .hps_0_hps_io_hps_io_qspi_inst_CLK (HPS_FLASH_DCLK),

        .hps_0_hps_io_hps_io_sdio_inst_CMD (HPS_SD_CMD),
        .hps_0_hps_io_hps_io_sdio_inst_CLK (HPS_SD_CLK),
        .hps_0_hps_io_hps_io_sdio_inst_D0  (HPS_SD_DATA[0]),
        .hps_0_hps_io_hps_io_sdio_inst_D1  (HPS_SD_DATA[1]),
        .hps_0_hps_io_hps_io_sdio_inst_D2  (HPS_SD_DATA[2]),
        .hps_0_hps_io_hps_io_sdio_inst_D3  (HPS_SD_DATA[3]),

        .hps_0_hps_io_hps_io_usb1_inst_D0  (HPS_USB_DATA[0]),
        .hps_0_hps_io_hps_io_usb1_inst_D1  (HPS_USB_DATA[1]),
        .hps_0_hps_io_hps_io_usb1_inst_D2  (HPS_USB_DATA[2]),
        .hps_0_hps_io_hps_io_usb1_inst_D3  (HPS_USB_DATA[3]),
        .hps_0_hps_io_hps_io_usb1_inst_D4  (HPS_USB_DATA[4]),
        .hps_0_hps_io_hps_io_usb1_inst_D5  (HPS_USB_DATA[5]),
        .hps_0_hps_io_hps_io_usb1_inst_D6  (HPS_USB_DATA[6]),
        .hps_0_hps_io_hps_io_usb1_inst_D7  (HPS_USB_DATA[7]),
        .hps_0_hps_io_hps_io_usb1_inst_CLK (HPS_USB_CLKOUT),
        .hps_0_hps_io_hps_io_usb1_inst_STP (HPS_USB_STP),
        .hps_0_hps_io_hps_io_usb1_inst_DIR (HPS_USB_DIR),
        .hps_0_hps_io_hps_io_usb1_inst_NXT (HPS_USB_NXT),

        .hps_0_hps_io_hps_io_spim0_inst_CLK  (HPS_LCM_SPIM_CLK),
        .hps_0_hps_io_hps_io_spim0_inst_MOSI (HPS_LCM_SPIM_MOSI),
        .hps_0_hps_io_hps_io_spim0_inst_MISO (HPS_LCM_SPIM_MISO),
        .hps_0_hps_io_hps_io_spim0_inst_SS0  (HPS_LCM_SPIM_SS),
        .hps_0_hps_io_hps_io_spim1_inst_CLK  (HPS_SPIM_CLK),
        .hps_0_hps_io_hps_io_spim1_inst_MOSI (HPS_SPIM_MOSI),
        .hps_0_hps_io_hps_io_spim1_inst_MISO (HPS_SPIM_MISO),
        .hps_0_hps_io_hps_io_spim1_inst_SS0  (HPS_SPIM_SS),

        .hps_0_hps_io_hps_io_uart0_inst_RX (HPS_UART_RX),
        .hps_0_hps_io_hps_io_uart0_inst_TX (HPS_UART_TX),
        .hps_0_hps_io_hps_io_i2c0_inst_SDA (HPS_I2C1_SDAT),
        .hps_0_hps_io_hps_io_i2c0_inst_SCL (HPS_I2C1_SCLK),
        .hps_0_hps_io_hps_io_i2c1_inst_SDA (HPS_I2C2_SDAT),
        .hps_0_hps_io_hps_io_i2c1_inst_SCL (HPS_I2C2_SCLK),

        .hps_0_hps_io_hps_io_gpio_inst_GPIO09 (HPS_CONV_USB_N),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO35 (HPS_ENET_INT_N),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO37 (HPS_LCM_BK),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO40 (HPS_LTC_GPIO),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO41 (HPS_LCM_D_C),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO44 (HPS_LCM_RST_N),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO48 (HPS_I2C_CONTROL),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO53 (HPS_LED),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO54 (HPS_KEY),
        .hps_0_hps_io_hps_io_gpio_inst_GPIO61 (HPS_GSENSOR_INT),

        .hps_0_h2f_reset_reset_n              (),
        .hps_0_f2h_cold_reset_req_reset_n     (1'b1),
        .hps_0_f2h_warm_reset_req_reset_n     (1'b1),
        .hps_0_f2h_debug_reset_req_reset_n    (1'b1),
        .hps_0_f2h_stm_hw_events_stm_hwevents (28'd0)
    );

    pedal_core core (
        .CLOCK_50      (CLOCK_50),
        .chain         (pedal_chain),
        .params        (pedal_params),
        .AUD_XCK       (AUD_XCK),
        .AUD_BCLK      (AUD_BCLK),
        .AUD_ADCLRCK   (AUD_ADCLRCK),
        .AUD_DACLRCK   (AUD_DACLRCK),
        .AUD_ADCDAT    (AUD_ADCDAT),
        .AUD_DACDAT    (AUD_DACDAT),
        .FPGA_I2C_SCLK (FPGA_I2C_SCLK),
        .FPGA_I2C_SDAT (FPGA_I2C_SDAT),
        .LEDR          (LEDR),
        .HEX0 (HEX0), .HEX1 (HEX1), .HEX2 (HEX2), .HEX3 (HEX3), .HEX4 (HEX4), .HEX5 (HEX5)
    );

endmodule
