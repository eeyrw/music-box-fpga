#include "device/dcd.h"

#include "pico/platform.h"
#include "portable/raspberrypi/rp2040/rp2040_usb.h"

/* Pico SDK 2.3.0 contains TinyUSB 0.18.0. Its RP2040
 * dcd_edpt_iso_activate() resets TinyUSB's software busy flag when Linux
 * selects an AudioStreaming alternate setting, but it does not abort an
 * isochronous transfer that is still AVAILABLE in USB DPRAM. A quick
 * alt-setting close/open therefore starts EP 0x81 twice and the RP2040 driver
 * panics with "ep 81 was already available".
 *
 * TinyUSB fixed this upstream in commit 102c1991d by aborting an active
 * transfer before reactivating an allocated isochronous endpoint. Keep this
 * narrow link-time wrapper until the vendored Pico SDK advances past that fix.
 * It touches hardware only when the stale AVAILABLE bit proves that a transfer
 * is still armed, so the first activation and post-reset activation are left
 * unchanged. RP2040 revision B2 and later implement the endpoint-abort handshake
 * reliably; this project's physical RP2040 reports revision 2. */

bool __real_dcd_edpt_iso_activate(
    uint8_t rhport, const tusb_desc_endpoint_t *endpoint_descriptor);

bool __wrap_dcd_edpt_iso_activate(
    uint8_t rhport, const tusb_desc_endpoint_t *endpoint_descriptor) {
    const uint8_t endpoint_address = endpoint_descriptor->bEndpointAddress;
    const uint8_t endpoint_number = tu_edpt_number(endpoint_address);
    const tusb_dir_t direction = tu_edpt_dir(endpoint_address);
    io_rw_32 *const buffer_control =
        direction == TUSB_DIR_IN
            ? &usb_dpram->ep_buf_ctrl[endpoint_number].in
            : &usb_dpram->ep_buf_ctrl[endpoint_number].out;

    if ((*buffer_control & USB_BUF_CTRL_AVAIL) != 0u) {
        const uint32_t abort_mask =
            1u << ((endpoint_number << 1u) |
                   (direction == TUSB_DIR_IN ? 0u : 1u));

        if (rp2040_chip_version() >= 2u) {
            usb_hw_set->abort = abort_mask;
            while ((usb_hw->abort_done & abort_mask) != abort_mask) {
                tight_loop_contents();
            }
        }

        /* Isochronous endpoints do not use DATA0/DATA1 sequencing. Clearing
         * the old length/FULL/AVAILABLE state returns buffer 0 to idle. The
         * SDK's transfer-start path then resets its private active state before
         * arming the newly selected stream. */
        *buffer_control = 0u;

        if (rp2040_chip_version() >= 2u) {
            usb_hw_clear->abort_done = abort_mask;
            usb_hw_clear->abort = abort_mask;
        }
    }

    return __real_dcd_edpt_iso_activate(rhport, endpoint_descriptor);
}
