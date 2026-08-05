#include "i2s_capture.h"
#if !APP_USB_CAPTURE_ONLY
#include "msf2_example.h"
#endif
#include "usb_audio_config.h"
#include "usb_audio_rate_match.h"

#if !APP_USB_CAPTURE_ONLY
#include "hardware/spi.h"
#include "hardware/sync.h"
#endif
#include "hardware/clocks.h"
#include "hardware/watchdog.h"
#include "pico/binary_info.h"
#include "pico/stdlib.h"
#include "tusb.h"

#include <stddef.h>
#include <stdint.h>

static repeating_timer_t app_timer;
static bool audio_started;
static int16_t usb_audio_samples[APP_USB_AUDIO_MAX_FRAMES * 2u];

_Static_assert(APP_USB_AUDIO_SAMPLE_RATE_HZ % 1000u == 0u,
               "nominal USB packet must contain an integral frame count");
_Static_assert(APP_USB_AUDIO_NOMINAL_FRAMES ==
                   APP_USB_AUDIO_SAMPLE_RATE_HZ / 1000u,
               "USB nominal packet size disagrees with sample rate");
_Static_assert(APP_USB_AUDIO_EP_MAX_PACKET ==
                   APP_USB_AUDIO_MAX_FRAMES * 2u * sizeof(int16_t),
               "USB endpoint cannot hold the largest stereo audio packet");

bi_decl(bi_program_description(
    "USB MIDI synth controller and stereo FPGA I2S capture"));
bi_decl(bi_program_feature("USB MIDI 1.0 input"));
bi_decl(bi_program_feature("USB Audio Class 2 stereo 48 kHz capture"));
#if !APP_USB_CAPTURE_ONLY
bi_decl(bi_3pins_with_names(
    PICO_DEFAULT_SPI_CSN_PIN, "FPGA SPI CS",
    PICO_DEFAULT_SPI_SCK_PIN, "FPGA SPI SCLK",
    PICO_DEFAULT_SPI_TX_PIN, "FPGA SPI MOSI"));
#endif
bi_decl(bi_3pins_with_names(
    APP_I2S_BCLK_PIN, "FPGA I2S BCLK",
    APP_I2S_LRCLK_PIN, "FPGA I2S LRCLK",
    APP_I2S_DATA_PIN, "FPGA I2S SDATA"));

#if !APP_USB_CAPTURE_ONLY
int platform_spi_write_mode0_cs0(const uint8_t *bytes, size_t byte_count) {
    int written;
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, false);
    written = spi_write_blocking(spi_default, bytes, byte_count);
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, true);
    return written == (int)byte_count ? 0 : -1;
}

uint32_t platform_irq_save(void) {
    return save_and_disable_interrupts();
}

void platform_irq_restore(uint32_t state) {
    restore_interrupts(state);
}
#endif

static bool app_timer_callback(repeating_timer_t *timer) {
    (void)timer;
    i2s_capture_tick_1ms();
#if !APP_USB_CAPTURE_ONLY
    app_synth_1ms_timer_isr();
#endif
    return true;
}

#if !APP_USB_CAPTURE_ONLY
static int dispatch_midi_packet(const uint8_t packet[4]) {
    /* USB-MIDI 1.0 packets are [Cable/CIN, status, data1, data2]. There is one
     * embedded cable, so routing needs no cable lookup. System/SysEx packets
     * have no MSF2 synth action; all MIDI channel voice messages are handled. */
    const uint8_t status = packet[1];
    const uint8_t channel = status & 0x0fu;
    const uint8_t data_1 = packet[2] & 0x7fu;
    const uint8_t data_2 = packet[3] & 0x7fu;

    switch (status & 0xf0u) {
        case 0x80u:
            return app_midi_note_off(channel, data_1);
        case 0x90u:
            if (data_2 == 0u) {
                return app_midi_note_off(channel, data_1);
            }
            return app_midi_note_on(channel, data_1, data_2);
        case 0xa0u:
            return app_midi_key_pressure(channel, data_1, data_2);
        case 0xb0u:
            return app_midi_control_change(channel, data_1, data_2);
        case 0xc0u:
            app_midi_program_change(channel, data_1);
            return 0;
        case 0xd0u:
            return app_midi_channel_pressure(channel, data_1);
        case 0xe0u:
            return app_midi_pitch_bend(channel, data_1, data_2);
        default:
            return 0;
    }
}
#endif

static int service_usb_midi(void) {
    uint8_t packet[4];
    while (tud_midi_available() != 0u && tud_midi_packet_read(packet)) {
#if !APP_USB_CAPTURE_ONLY
        const int result = dispatch_midi_packet(packet);
        if (result < 0) return result;
#else
        /* Keep the composite MIDI OUT endpoint drained in capture-only builds,
         * but deliberately perform no MSF2 lookup or FPGA command output. */
        (void)packet;
#endif
    }
    return 0;
}

static size_t fill_usb_audio_silence(
    int16_t samples[APP_USB_AUDIO_MAX_FRAMES * 2u]) {
    size_t sample;
    for (sample = 0u; sample < APP_USB_AUDIO_NOMINAL_FRAMES * 2u; ++sample) {
        samples[sample] = 0;
    }
    return APP_USB_AUDIO_NOMINAL_FRAMES;
}

static size_t fill_usb_audio_packet(
    int16_t samples[APP_USB_AUDIO_MAX_FRAMES * 2u]) {
    size_t available = i2s_capture_available();
    size_t requested;
    size_t captured;

    /* Clock loss is a normal cable/reset condition. Keep the already-open USB
     * isochronous pipe alive with nominal silence and discard stale ring data.
     * This avoids a run of zero-length packets while Linux is synchronously
     * stopping or reprobeing the ALSA stream. */
    if (!i2s_capture_clock_valid()) {
        audio_started = false;
        i2s_capture_discard();
        return fill_usb_audio_silence(samples);
    }

    /* Wait for 2 ms of I2S data before exposing live audio. Thereafter, vary
     * packet length rather than modifying samples:
     *
     *   low fill  -> 47 frames, allowing the capture ring to gain one frame
     *   nominal   -> 48 frames
     *   high fill -> 49 frames, draining one extra frame
     *
     * USB 2.0 permits an isochronous payload shorter than wMaxPacketSize, and
     * UAC2 asynchronous IN endpoints are specifically intended for a source
     * clock independent of SOF. This preserves every FPGA sample; it does not
     * drop a frame or duplicate the previous one to correct clock drift. */
    if (!audio_started) {
        if (available < APP_USB_AUDIO_TARGET_FRAMES) {
            return fill_usb_audio_silence(samples);
        }
        audio_started = true;
    }

    /* Clock validity has a short loss debounce. If the producer stops inside
     * that window, do not emit a short or zero packet: abandon the old stream
     * contents and return nominal silence until a fresh buffer is established. */
    if (available < APP_USB_AUDIO_NOMINAL_FRAMES - 1u) {
        audio_started = false;
        i2s_capture_discard();
        return fill_usb_audio_silence(samples);
    }

    requested = app_usb_audio_packet_frames(available);
    captured = i2s_capture_read(samples, requested);
    return captured;
}

bool tud_audio_tx_done_pre_load_cb(uint8_t rhport, uint8_t function_id,
                                   uint8_t endpoint, uint8_t alternate) {
    size_t frame_count;
    (void)rhport;
    (void)function_id;
    (void)endpoint;
    (void)alternate;
    frame_count = fill_usb_audio_packet(usb_audio_samples);
    (void)tud_audio_write(usb_audio_samples,
                          frame_count * 2u * sizeof(usb_audio_samples[0]));
    return true;
}

bool tud_audio_get_req_entity_cb(uint8_t rhport,
                                 const tusb_control_request_t *request) {
    static const audio_desc_channel_cluster_t input_channels = {
        .bNrChannels = 2u,
        .bmChannelConfig = AUDIO_CHANNEL_CONFIG_FRONT_LEFT |
                           AUDIO_CHANNEL_CONFIG_FRONT_RIGHT,
        .iChannelNames = 0u,
    };
    static const uint32_t sample_rate = APP_USB_AUDIO_SAMPLE_RATE_HZ;
    static uint8_t clock_valid;
    static const struct {
        uint16_t count;
        uint32_t minimum;
        uint32_t maximum;
        uint32_t resolution;
    } __attribute__((packed)) sample_rate_range = {
        1u, APP_USB_AUDIO_SAMPLE_RATE_HZ, APP_USB_AUDIO_SAMPLE_RATE_HZ, 0u
    };
    const uint8_t entity = (uint8_t)(request->wIndex >> 8);
    const uint8_t control = (uint8_t)(request->wValue >> 8);

    /* Input Terminal 1 advertises its Connector Control as read-only. Return
     * the same two-channel cluster encoded in the terminal and AS descriptors. */
    if (entity == APP_USB_AUDIO_INPUT_TERMINAL_ID &&
        control == AUDIO_TE_CTRL_CONNECTOR &&
        request->bRequest == AUDIO_CS_REQ_CUR) {
        return tud_audio_buffer_and_schedule_control_xfer(
            rhport, request, (void *)&input_channels, sizeof(input_channels));
    }
    /* External Clock Source 3 is nominally 48 kHz and not programmable. UAC2
     * still requires CUR and RANGE for Frequency; only CUR exists for Validity. */
    if (entity != APP_USB_AUDIO_CLOCK_SOURCE_ID) return false;
    if (control == AUDIO_CS_CTRL_SAM_FREQ) {
        if (request->bRequest == AUDIO_CS_REQ_CUR) {
            return tud_audio_buffer_and_schedule_control_xfer(
                rhport, request, (void *)&sample_rate, sizeof(sample_rate));
        }
        if (request->bRequest == AUDIO_CS_REQ_RANGE) {
            return tud_control_xfer(rhport, request,
                                    (void *)&sample_rate_range,
                                    sizeof(sample_rate_range));
        }
    } else if (control == AUDIO_CS_CTRL_CLK_VALID &&
               request->bRequest == AUDIO_CS_REQ_CUR) {
        clock_valid = i2s_capture_clock_valid() ? 1u : 0u;
        return tud_control_xfer(rhport, request, (void *)&clock_valid,
                                sizeof(clock_valid));
    }
    return false;
}

bool tud_audio_set_itf_close_EP_cb(uint8_t rhport,
                                   const tusb_control_request_t *request) {
    (void)rhport;
    (void)request;
    audio_started = false;
    return true;
}

#if !APP_USB_CAPTURE_ONLY
static void init_fpga_spi(void) {
    /* APP_FPGA_SPI_HZ is a requested ceiling. At the default 120 MHz peripheral
     * clock, RP2040's even prescaler produces exactly the tested 30 MHz rate;
     * other clock configurations may select a lower realizable rate. */
    (void)spi_init(spi_default, APP_FPGA_SPI_HZ);
    spi_set_format(spi_default, 8u, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST);
    gpio_set_function(PICO_DEFAULT_SPI_SCK_PIN, GPIO_FUNC_SPI);
    gpio_set_function(PICO_DEFAULT_SPI_TX_PIN, GPIO_FUNC_SPI);
    gpio_init(PICO_DEFAULT_SPI_CSN_PIN);
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, true);
    gpio_set_dir(PICO_DEFAULT_SPI_CSN_PIN, GPIO_OUT);
}
#endif

static void fatal_blink(void) {
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
    while (true) {
        gpio_xor_mask(1u << PICO_DEFAULT_LED_PIN);
        sleep_ms(100u);
    }
}

int main(void) {
    tusb_rhport_init_t usb_init = {
        .role = TUSB_ROLE_DEVICE,
        .speed = TUSB_SPEED_AUTO,
    };

    if (!set_sys_clock_khz(APP_SYS_CLOCK_KHZ, true)) fatal_blink();
#if !APP_USB_CAPTURE_ONLY
    init_fpga_spi();
#endif
    i2s_capture_init();
#if !APP_USB_CAPTURE_ONLY
    if (app_synth_init() != 0) fatal_blink();
#endif
    if (!add_repeating_timer_ms(-1, app_timer_callback, NULL, &app_timer)) {
        fatal_blink();
    }
    if (!tusb_init(BOARD_TUD_RHPORT, &usb_init)) fatal_blink();
    /* A firmware fault must not leave Linux blocked forever in a synchronous
     * USB audio ioctl. The watchdog pauses under SWD so normal debugging still
     * works, but resets a genuinely wedged main loop within two seconds. */
    watchdog_enable(2000u, true);

    while (true) {
        watchdog_update();
        tud_task();
        if (service_usb_midi() != 0) fatal_blink();
#if !APP_USB_CAPTURE_ONLY
        if (app_synth_service() != 0) fatal_blink();
#endif
        tight_loop_contents();
    }
}
