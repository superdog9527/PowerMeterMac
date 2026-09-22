#ifndef PM_USB_H
#define PM_USB_H
#include <stdint.h>
typedef struct pm_usb pm_usb;
// All control commands are serialized and allowlisted. 5000 mV is the documented device ceiling.
pm_usb *pm_open(const char *serial, char *error, int capacity);
int pm_list(char *json, int capacity);
int pm_command(pm_usb *usb, uint8_t opcode, const uint8_t *payload, int length, uint8_t *reply, int capacity);
int pm_read(pm_usb *usb, uint8_t *buffer, int capacity, int timeout_ms);
void pm_close(pm_usb *usb);
const char *pm_error(int code);
// Pure safety validation; also used by the command path. Does not access USB.
int pm_validate_command(uint8_t opcode, const uint8_t *payload, int length, int voltage_confirmed);
#endif
