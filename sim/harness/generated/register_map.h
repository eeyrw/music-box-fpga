// Generated from spec/register_map.json by tools/gen_register_map.py.
// Do not edit by hand.
#pragma once

#include <cstdint>

namespace render::regs {
constexpr int kBusAddrWidth = 16;
constexpr int kBusDataWidth = 32;
constexpr uint32_t kVersionValue = 0x00050000u;
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
constexpr uint16_t kOffRegionMode = 0x0020u;
constexpr uint16_t kOffPhaseInit = 0x0030u;
constexpr uint16_t kOffPhaseInc = 0x0034u;
constexpr uint16_t kOffPhaseIncRuntime = 0x0038u;
constexpr uint16_t kOffGainL = 0x0040u;
constexpr uint16_t kOffGainR = 0x0044u;
constexpr uint16_t kOffGainRuntime = 0x0048u;
constexpr uint16_t kOffEnvelopeLevel = 0x004cu;
constexpr uint16_t kOffFilterControl = 0x0050u;
constexpr uint16_t kOffFilterB0 = 0x0054u;
constexpr uint16_t kOffFilterB1 = 0x0058u;
constexpr uint16_t kOffFilterB2 = 0x005cu;
constexpr uint16_t kOffFilterA1 = 0x0060u;
constexpr uint16_t kOffFilterA2 = 0x0064u;
constexpr uint16_t kOffFilterCommit = 0x0068u;
constexpr uint16_t kOffControl = 0x0070u;
constexpr uint16_t kOffCommit = 0x0074u;
constexpr uint16_t kOffReleaseControl = 0x0078u;
constexpr uint16_t kOffStatus = 0x007cu;

constexpr uint16_t kVersion = 0x3000u;
constexpr uint16_t kSystemStatus = 0x3010u;
constexpr uint16_t kDebugEventFlags = 0x3014u;
constexpr uint16_t kAudioStatus = 0x3018u;
constexpr uint16_t kRenderStatus = 0x301cu;
constexpr uint16_t kMemoryStatus = 0x3020u;
constexpr uint16_t kUnderrunCount = 0x3024u;
constexpr uint16_t kSampleDropCount = 0x3028u;
constexpr uint16_t kRenderDeadlineMissCount = 0x302cu;
constexpr uint16_t kMemHitCount = 0x3030u;
constexpr uint16_t kMemMissCount = 0x3034u;
constexpr uint16_t kMemResponseCount = 0x3038u;
constexpr uint16_t kPlatformStatus = 0x3040u;
constexpr uint16_t kPlatformErrors = 0x3044u;
constexpr uint16_t kPlatformBytesLoaded = 0x3048u;
constexpr uint16_t kPlatformSf2Size = 0x3050u;
constexpr uint16_t kPlatformCurrentLba = 0x3058u;
constexpr uint16_t kPlatformDdrStatus = 0x305cu;
constexpr uint16_t kDdrDebugControl = 0x3060u;
constexpr uint16_t kDdrDebugStatus = 0x3064u;
constexpr uint16_t kDdrDebugAddr = 0x3068u;
constexpr uint16_t kDdrDebugByteEnable = 0x306cu;
constexpr uint16_t kDdrDebugData0 = 0x3070u;
constexpr uint16_t kDdrDebugData1 = 0x3074u;
constexpr uint16_t kDdrDebugData2 = 0x3078u;
constexpr uint16_t kDdrDebugData3 = 0x307cu;

constexpr int kRegionModeStereoBit = 0;
constexpr int kRegionModeLoopModeLsb = 1;
constexpr int kRegionModeLoopModeWidth = 2;
constexpr uint32_t kRegionModeMask = 0x00000007u;
constexpr uint32_t kControlEnableMask = 0x00000001u;
constexpr uint32_t kCommitApplyMask = 0x00000001u;
constexpr uint32_t kFilterControlEnableMask = 0x00000001u;
constexpr uint32_t kFilterCommitApplyMask = 0x00000001u;
constexpr uint32_t kDebugEventFlagsUnderrunMask = 0x00000001u;
constexpr uint32_t kDebugEventFlagsSampleDropMask = 0x00000002u;
constexpr uint32_t kDebugEventFlagsRenderDeadlineMissMask = 0x00000004u;
constexpr uint32_t kDebugEventFlagsMemHitMask = 0x00000008u;
constexpr uint32_t kDebugEventFlagsMemMissMask = 0x00000010u;
constexpr uint32_t kDebugEventFlagsMemResponseMask = 0x00000020u;
constexpr uint32_t kPlatformStatusDebugPresentMask = 0x00000001u;
constexpr uint32_t kPlatformStatusErrorPresentMask = 0x00000002u;
constexpr uint32_t kPlatformStatusDdrCalibratedMask = 0x00000004u;
constexpr uint32_t kPlatformStatusDdrUiResetMask = 0x00000008u;
constexpr uint32_t kPlatformStatusSdInitializedMask = 0x00000010u;
constexpr uint32_t kPlatformStatusAssetLoadedMask = 0x00000020u;
constexpr uint32_t kDdrDebugControlStartMask = 0x00000001u;
constexpr uint32_t kDdrDebugControlWriteMask = 0x00000002u;
constexpr uint32_t kDdrDebugControlClearMask = 0x00000004u;
constexpr uint32_t kDdrDebugStatusPresentMask = 0x00000001u;
constexpr uint32_t kDdrDebugStatusReadyMask = 0x00000002u;
constexpr uint32_t kDdrDebugStatusDoneMask = 0x00000008u;
constexpr uint32_t kDdrDebugStatusErrorMask = 0x00000010u;

constexpr uint32_t kQ15Full = 0x00007fffu;
constexpr uint32_t kFilterB0UnityQ428 = 0x10000000u;

constexpr uint16_t voice_addr(int voice, uint16_t offset) {
  return uint16_t(kVoiceBase + voice * kVoiceStride + offset);
}

}  // namespace render::regs
