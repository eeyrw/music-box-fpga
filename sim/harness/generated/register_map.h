// Generated from spec/register_map.json by tools/gen_register_map.py.
// Do not edit by hand.
#pragma once

#include <cstdint>

namespace render::regs {
constexpr int kBusAddrWidth = 16;
constexpr int kBusDataWidth = 32;
constexpr uint32_t kVersionValue = 0x00060000u;
constexpr uint16_t kVoiceBase = 0x0100u;
constexpr uint16_t kVoiceStride = 0x0100u;

constexpr uint16_t kOffBaseAddr = 0x0000u;
constexpr uint16_t kOffBaseAddrR = 0x0004u;
constexpr uint16_t kOffLength = 0x0008u;
constexpr uint16_t kOffLengthR = 0x000cu;
constexpr uint16_t kOffLoopStart = 0x0010u;
constexpr uint16_t kOffLoopStartR = 0x0014u;
constexpr uint16_t kOffLoopEnd = 0x0018u;
constexpr uint16_t kOffLoopEndR = 0x001cu;
constexpr uint16_t kOffPhaseInit = 0x0020u;
constexpr uint16_t kOffPhaseInc = 0x0024u;
constexpr uint16_t kOffGain = 0x0028u;
constexpr uint16_t kOffEnvelope = 0x002cu;
constexpr uint16_t kOffFilterControl = 0x0030u;
constexpr uint16_t kOffFilterB0B1 = 0x0034u;
constexpr uint16_t kOffFilterB2A1 = 0x0038u;
constexpr uint16_t kOffFilterA2 = 0x003cu;
constexpr uint16_t kOffVoiceControl = 0x0040u;
constexpr uint16_t kOffPhaseIncRuntime = 0x0044u;
constexpr uint16_t kOffGainRuntime = 0x0048u;
constexpr uint16_t kOffEnvelopeRuntime = 0x004cu;
constexpr uint16_t kOffReleaseControl = 0x0050u;
constexpr uint16_t kOffStatus = 0x0054u;

constexpr uint16_t kVersion = 0x3000u;
constexpr uint16_t kSystemStatus = 0x3010u;
constexpr uint16_t kCommonEventFlags = 0x3014u;
constexpr uint16_t kAudioStatus = 0x3018u;
constexpr uint16_t kRenderStatus = 0x301cu;
constexpr uint16_t kMemoryStatus = 0x3020u;
constexpr uint16_t kUnderrunCount = 0x3024u;
constexpr uint16_t kSampleDropCount = 0x3028u;
constexpr uint16_t kRenderDeadlineMissCount = 0x302cu;
constexpr uint16_t kMemResponseCount = 0x3038u;
constexpr uint16_t kPlatformStatus = 0x3040u;
constexpr uint16_t kPlatformErrors = 0x3044u;
constexpr uint16_t kPlatformBytesLoaded = 0x3048u;
constexpr uint16_t kPlatformSf2Size = 0x3050u;
constexpr uint16_t kPlatformCurrentLba = 0x3058u;
constexpr uint16_t kPlatformDdrStatus = 0x305cu;
constexpr uint16_t kDdrAccessControl = 0x3060u;
constexpr uint16_t kDdrAccessStatus = 0x3064u;
constexpr uint16_t kDdrAccessAddr = 0x3068u;
constexpr uint16_t kDdrAccessByteEnable = 0x306cu;
constexpr uint16_t kDdrAccessData0 = 0x3070u;
constexpr uint16_t kDdrAccessData1 = 0x3074u;
constexpr uint16_t kDdrAccessData2 = 0x3078u;
constexpr uint16_t kDdrAccessData3 = 0x307cu;

constexpr int kVoiceControlStereoBit = 0;
constexpr int kVoiceControlLoopModeLsb = 1;
constexpr int kVoiceControlLoopModeWidth = 2;
constexpr uint32_t kVoiceControlEnableMask = 0x00000008u;
constexpr uint32_t kVoiceControlApplyMask = 0x00000010u;
constexpr uint32_t kVoiceControlMask = 0x0000000fu;
constexpr uint32_t kFilterControlEnableMask = 0x00000001u;
constexpr uint32_t kFilterA2ApplyMask = 0x00010000u;
constexpr uint32_t kCommonEventFlagsUnderrunMask = 0x00000001u;
constexpr uint32_t kCommonEventFlagsSampleDropMask = 0x00000002u;
constexpr uint32_t kCommonEventFlagsRenderDeadlineMissMask = 0x00000004u;
constexpr uint32_t kCommonEventFlagsMemResponseMask = 0x00000008u;
constexpr uint32_t kPlatformStatusPlatformRegsPresentMask = 0x00000001u;
constexpr uint32_t kPlatformStatusErrorPresentMask = 0x00000002u;
constexpr uint32_t kPlatformStatusDdrCalibratedMask = 0x00000004u;
constexpr uint32_t kPlatformStatusDdrUiResetMask = 0x00000008u;
constexpr uint32_t kPlatformStatusSdInitializedMask = 0x00000010u;
constexpr uint32_t kPlatformStatusAssetLoadedMask = 0x00000020u;
constexpr uint32_t kDdrAccessControlStartMask = 0x00000001u;
constexpr uint32_t kDdrAccessControlWriteMask = 0x00000002u;
constexpr uint32_t kDdrAccessControlClearMask = 0x00000004u;
constexpr uint32_t kDdrAccessStatusPresentMask = 0x00000001u;
constexpr uint32_t kDdrAccessStatusReadyMask = 0x00000002u;
constexpr uint32_t kDdrAccessStatusDoneMask = 0x00000008u;
constexpr uint32_t kDdrAccessStatusErrorMask = 0x00000010u;

constexpr uint32_t kQ15Full = 0x00007fffu;
constexpr uint32_t kFilterB0UnityQ214 = 0x00004000u;

constexpr uint16_t voice_addr(int voice, uint16_t offset) {
  return uint16_t(kVoiceBase + voice * kVoiceStride + offset);
}

}  // namespace render::regs
