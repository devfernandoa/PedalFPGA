TARGET = pedalctl
BOARD_IP ?= 169.254.0.13
BOARD = root@$(BOARD_IP)
REMOTE_DIR = /home/root
RBF = ../output_files/soc_system.rbf

CROSS_COMPILE ?= $(CURDIR)/../../gcc-linaro-7.4.1-2019.02-x86_64_arm-linux-gnueabihf/bin/arm-linux-gnueabihf-
CC = $(CROSS_COMPILE)gcc
CFLAGS = -O2 -Wall -Wextra -std=gnu99

build: $(TARGET)

$(TARGET): pedalctl.c
	$(CC) $(CFLAGS) $< -o $@ -lm

# Pitch detector self-check, built and run on this machine (no board needed)
test: pedalctl.c
	cc $(CFLAGS) $< -o /tmp/pedalctl-test -lm && /tmp/pedalctl-test pitchtest

deploy: $(TARGET)
	scp -O $(TARGET) $(BOARD):$(REMOTE_DIR)/

# .sof -> compressed .rbf, the format u-boot's "fpga load" expects (see u-boot.scr on the SD card)
rbf: $(RBF)
$(RBF): ../output_files/PedalFPGA.sof
	quartus_cpf -c -o bitstream_compression=on $< $@

# Copies the bitstream to the SD card's FAT partition (where u-boot looks for it) and reboots.
deploy-rbf: $(RBF)
	scp -O $(RBF) $(BOARD):/tmp/soc_system.rbf
	ssh $(BOARD) "mkdir -p /mnt/boot && mount /dev/mmcblk0p1 /mnt/boot && cp /tmp/soc_system.rbf /mnt/boot/ && sync && umount /mnt/boot && reboot"

# Web UI: static page + CGI (web/), served by busybox httpd on port 80, started at boot by systemd.
deploy-web: $(TARGET)
	chmod +x web/cgi-bin/pedal
	scp -O $(TARGET) $(BOARD):$(REMOTE_DIR)/
	scp -O -r web pedal-web.service $(BOARD):$(REMOTE_DIR)/
	ssh $(BOARD) "mv $(REMOTE_DIR)/pedal-web.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable pedal-web && systemctl restart pedal-web && sync"

clean:
	rm -f $(TARGET)

.PHONY: build test deploy rbf deploy-rbf deploy-web clean
