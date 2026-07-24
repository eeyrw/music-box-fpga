// Generated from spec/register_map.json by tools/gen_register_map.py.
// Do not edit by hand.
#pragma once

#include <cstdint>

namespace render::regs {
constexpr int kBusAddrWidth = 16;
constexpr int kBusDataWidth = 32;
constexpr uint32_t kVersionValue = 0x00070000u;

constexpr uint16_t kVersion = 0x9000u;
constexpr uint16_t kSystemStatus = 0x9010u;
constexpr uint16_t kCommonEventFlags = 0x9014u;
constexpr uint16_t kAudioStatus = 0x9018u;
constexpr uint16_t kRenderStatus = 0x901cu;
constexpr uint16_t kMemoryStatus = 0x9020u;
constexpr uint16_t kUnderrunCount = 0x9024u;
constexpr uint16_t kSampleDropCount = 0x9028u;
constexpr uint16_t kRenderDeadlineMissCount = 0x902cu;
constexpr uint16_t kCurrentSample = 0x9030u;
constexpr uint16_t kCmdFifoStatus = 0x9034u;
constexpr uint16_t kMemResponseCount = 0x9038u;
constexpr uint16_t kCmdFifoData = 0x903cu;
constexpr uint16_t kCmdErrorStatus = 0x9094u;
constexpr uint16_t kCmdActionStatus = 0x909cu;
constexpr uint16_t kDebugVoiceIndex = 0x90a0u;
constexpr uint16_t kDebugVoiceCapture = 0x90a4u;
constexpr uint16_t kDebugVoiceStatus = 0x90a8u;
constexpr uint16_t kDebugVoiceBaseL = 0x90acu;
constexpr uint16_t kDebugVoiceBaseR = 0x90b0u;
constexpr uint16_t kDebugVoiceLengthL = 0x90b4u;
constexpr uint16_t kDebugVoiceLengthR = 0x90b8u;
constexpr uint16_t kDebugVoiceLoopStartL = 0x90bcu;
constexpr uint16_t kDebugVoiceLoopStartR = 0x90c0u;
constexpr uint16_t kDebugVoiceLoopEndL = 0x90c4u;
constexpr uint16_t kDebugVoiceLoopEndR = 0x90c8u;
constexpr uint16_t kDebugVoicePhaseInit = 0x90ccu;
constexpr uint16_t kDebugVoicePhaseInc = 0x90d0u;
constexpr uint16_t kDebugVoiceGain = 0x90d4u;
constexpr uint16_t kDebugVoiceEnvelope = 0x90d8u;
constexpr uint16_t kDebugVoiceFilterControl = 0x90dcu;
constexpr uint16_t kDebugVoiceFilterB0B1 = 0x90e0u;
constexpr uint16_t kDebugVoiceFilterB2A1 = 0x90e4u;
constexpr uint16_t kDebugEnvDelay = 0x90e8u;
constexpr uint16_t kDebugEnvAttackStep = 0x90ecu;
constexpr uint16_t kDebugEnvHold = 0x90f0u;
constexpr uint16_t kDebugEnvDecayStep = 0x90f4u;
constexpr uint16_t kDebugEnvSustain = 0x90f8u;
constexpr uint16_t kDebugEnvReleaseStep = 0x90fcu;
constexpr uint16_t kDebugEnvElapsed = 0x9100u;
constexpr uint16_t kDebugEnvAttackLevel = 0x9104u;
constexpr uint16_t kDebugEnvAttenuation = 0x9108u;
constexpr uint16_t kPlatformStatus = 0x9040u;
constexpr uint16_t kPlatformErrors = 0x9044u;
constexpr uint16_t kPlatformBytesLoaded = 0x9048u;
constexpr uint16_t kPlatformSf2Size = 0x9050u;
constexpr uint16_t kPlatformCurrentLba = 0x9058u;
constexpr uint16_t kPlatformDdrStatus = 0x905cu;
constexpr uint16_t kDdrAccessControl = 0x9060u;
constexpr uint16_t kDdrAccessStatus = 0x9064u;
constexpr uint16_t kDdrAccessAddr = 0x9068u;
constexpr uint16_t kDdrAccessByteEnable = 0x906cu;
constexpr uint16_t kDdrAccessData0 = 0x9070u;
constexpr uint16_t kDdrAccessData1 = 0x9074u;
constexpr uint16_t kDdrAccessData2 = 0x9078u;
constexpr uint16_t kDdrAccessData3 = 0x907cu;

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

}  // namespace render::regs
