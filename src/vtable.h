#pragma once
#include <systemd/sd-bus.h>

extern const sd_bus_vtable notification_vtable[];
const void* get_notification_vtable(void);

