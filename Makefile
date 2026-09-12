# the default target, build the sources for openSUSE image
all: shellcheck check-format

shellcheck:
	shellcheck usb-wakeup-disable.sh

check-format:
	shfmt -i 2 -sr usb-wakeup-disable.sh

format:
	shfmt -i 2 -sr -w usb-wakeup-disable.sh

.PHONY: all shellcheck check-format format
