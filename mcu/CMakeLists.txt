cmake_minimum_required(VERSION 3.13)

if(NOT DEFINED PICO_SDK_PATH)
    set(PICO_SDK_PATH "${CMAKE_CURRENT_LIST_DIR}/../third_party/pico-sdk")
endif()

include("${PICO_SDK_PATH}/external/pico_sdk_import.cmake")

project(music_box_mcu C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

set(APP_SYS_CLOCK_KHZ 120000 CACHE STRING "RP2040 system clock in kHz")
set(APP_FPGA_SPI_HZ 30000000 CACHE STRING "FPGA command SPI clock in Hz")
set(APP_I2S_BCLK_PIN 8 CACHE STRING "GPIO receiving FPGA I2S BCLK")
set(APP_I2S_LRCLK_PIN 9 CACHE STRING "GPIO receiving FPGA I2S LRCLK")
set(APP_I2S_DATA_PIN 10 CACHE STRING "GPIO receiving FPGA I2S SDATA")

set(MSF2_IMAGE "${CMAKE_CURRENT_LIST_DIR}/../build/assets/wavetable.msf2"
    CACHE FILEPATH "Compact-v2 MSF2 image embedded in RP2040 flash")
if(NOT IS_ABSOLUTE "${MSF2_IMAGE}")
    get_filename_component(MSF2_IMAGE "${MSF2_IMAGE}" ABSOLUTE
        BASE_DIR "${CMAKE_CURRENT_LIST_DIR}/..")
endif()
if(NOT EXISTS "${MSF2_IMAGE}")
    message(FATAL_ERROR
        "MSF2 image not found: ${MSF2_IMAGE}\n"
        "Generate it with 'make mcu-sf2-asset' or set -DMSF2_IMAGE=<path>.")
endif()

set(MSF2_IMAGE_OBJECT "${CMAKE_CURRENT_BINARY_DIR}/app_msf2_image.o")
add_custom_command(
    OUTPUT "${MSF2_IMAGE_OBJECT}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "${MSF2_IMAGE}" app_msf2_image.bin
    COMMAND "${CMAKE_OBJCOPY}"
            -I binary -O elf32-littlearm -B arm
            --rename-section .data=.rodata,alloc,load,readonly,data,contents
            --redefine-sym _binary_app_msf2_image_bin_start=app_msf2_image_start
            --redefine-sym _binary_app_msf2_image_bin_end=app_msf2_image_end
            app_msf2_image.bin app_msf2_image.o
    DEPENDS "${MSF2_IMAGE}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    VERBATIM
)
set_source_files_properties("${MSF2_IMAGE_OBJECT}" PROPERTIES
    EXTERNAL_OBJECT TRUE
    GENERATED TRUE
)

add_library(msf2 STATIC
    msf2.c
)
target_compile_options(msf2 PRIVATE -Wall -Wextra -Werror -Wpedantic)
target_include_directories(msf2 PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}
)

add_executable(music_box_mcu
    i2s_capture.c
    main.c
    msf2_example.c
    usb_audio_rate_match.c
    usb_descriptors.c
    "${MSF2_IMAGE_OBJECT}"
)
set_source_files_properties(
    i2s_capture.c
    main.c
    msf2_example.c
    usb_audio_rate_match.c
    usb_descriptors.c
    PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra;-Werror"
)
target_compile_definitions(music_box_mcu PRIVATE
    APP_SYS_CLOCK_KHZ=${APP_SYS_CLOCK_KHZ}
    APP_FPGA_SPI_HZ=${APP_FPGA_SPI_HZ}
    APP_I2S_BCLK_PIN=${APP_I2S_BCLK_PIN}
    APP_I2S_LRCLK_PIN=${APP_I2S_LRCLK_PIN}
    APP_I2S_DATA_PIN=${APP_I2S_DATA_PIN}
)
target_link_libraries(music_box_mcu PRIVATE
    msf2
    hardware_dma
    hardware_pio
    hardware_spi
    pico_unique_id
    pico_stdlib
    tinyusb_device
)

pico_enable_stdio_uart(music_box_mcu 0)
pico_enable_stdio_usb(music_box_mcu 0)
pico_add_extra_outputs(music_box_mcu)

add_custom_command(TARGET music_box_mcu POST_BUILD
    COMMAND sh "${CMAKE_CURRENT_LIST_DIR}/check_usb_descriptor.sh"
            "${CMAKE_OBJCOPY}"
            "${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/music_box_mcu.dir/usb_descriptors.c.o"
    VERBATIM
)
