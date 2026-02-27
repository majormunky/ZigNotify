#include <systemd/sd-bus.h>
#include "vtable.h"

int handle_get_capabilities(sd_bus_message *msg, void *userdata, sd_bus_error *err);
int handle_get_server_information(sd_bus_message *msg, void *userdata, sd_bus_error *err);
int handle_notify(sd_bus_message *msg, void *userdata, sd_bus_error *err);
int handle_close_notification(sd_bus_message *msg, void *userdata, sd_bus_error *err);

const sd_bus_vtable notification_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("GetCapabilities", "", "as", handle_get_capabilities, 0),
    SD_BUS_METHOD("GetServerInformation", "", "ssss", handle_get_server_information, 0),
    SD_BUS_METHOD("Notify", "susssasa{sv}i", "u", handle_notify, 0),
    SD_BUS_METHOD("CloseNotification", "u", "", handle_close_notification, 0),
    SD_BUS_VTABLE_END
};

const void* get_notification_vtable(void) {
    return notification_vtable;
}
