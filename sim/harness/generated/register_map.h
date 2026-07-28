// Generated from spec/register_map.json by tools/gen_register_map.py.
// Do not edit by hand.
#pragma once

#include <cstdint>

namespace render::regs {
constexpr int kBusAddrWidth = 16;
constexpr int kBusDataWidth = 32;
constexpr uint32_t kVersionValue = 0x000a0000u;

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
constexpr uint16_t kCompressorStatus = 0x910cu;
constexpr uint16_t kCompressorGainReduction = 0x9110u;
constexpr uint16_t kCompressorTargetGainReduction = 0x9114u;
constexpr uint16_t kCompressorDetectorPeak = 0x9118u;
constexpr uint16_t kCompressorMaxGainReduction = 0x911cu;
constexpr uint16_t kCompressorMaxDetectorPeak = 0x9120u;
constexpr uint16_t kCompressorInputFrameCount = 0x9124u;
constexpr uint16_t kCompressorOutputFrameCount = 0x9128u;
constexpr uint16_t kCompressorCompressedFrameCount = 0x912cu;
constexpr uint16_t kCompressorSaturationCount = 0x9130u;
constexpr uint16_t kEffectStatus = 0x9134u;
constexpr uint16_t kEffectInputFrameCount = 0x9138u;
constexpr uint16_t kEffectOutputFrameCount = 0x913cu;
constexpr uint16_t kEffectSaturationCount = 0x9140u;
constexpr uint16_t kEffectMaxProcessingCycles = 0x9144u;
constexpr uint16_t kChorusHistoryLevel = 0x9148u;
constexpr uint16_t kChorusLfoPhase = 0x914cu;
constexpr uint16_t kChorusSaturationCount = 0x9150u;
constexpr uint16_t kReverbStatus = 0x9154u;
constexpr uint16_t kReverbSaturationCount = 0x9158u;
constexpr uint16_t kReverbMaxProcessingCycles = 0x915cu;
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
constexpr uint32_t kPlatformStatusSdCardPresentMask = 0x00008000u;
constexpr uint32_t kPlatformStatusSdHighSpeedActiveMask = 0x00010000u;
constexpr uint32_t kDdrAccessControlStartMask = 0x00000001u;
constexpr uint32_t kDdrAccessControlWriteMask = 0x00000002u;
constexpr uint32_t kDdrAccessControlClearMask = 0x00000004u;
constexpr uint32_t kDdrAccessStatusPresentMask = 0x00000001u;
constexpr uint32_t kDdrAccessStatusReadyMask = 0x00000002u;
constexpr uint32_t kDdrAccessStatusDoneMask = 0x00000008u;
constexpr uint32_t kDdrAccessStatusErrorMask = 0x00000010u;
constexpr uint32_t kCmdFifoStatusWordEmptyMask = 0x00000001u;
constexpr uint32_t kCmdFifoStatusWordFullMask = 0x00000002u;
constexpr int kCmdFifoStatusWordLevelLsb = 2;
constexpr int kCmdFifoStatusWordLevelWidth = 14;
constexpr uint32_t kCmdFifoStatusParserIdleMask = 0x00010000u;
constexpr uint32_t kCmdFifoStatusActionPendingMask = 0x00020000u;
constexpr uint32_t kCmdFifoStatusCommandErrorMask = 0x40000000u;
constexpr uint32_t kCmdFifoStatusStaleGenerationMask = 0x80000000u;
constexpr uint32_t kCmdErrorStatusCommandErrorMask = 0x00000001u;
constexpr uint32_t kCmdErrorStatusStaleGenerationMask = 0x00000002u;
constexpr uint32_t kCmdActionStatusIdleMask = 0x00000001u;
constexpr uint32_t kCmdActionStatusPendingMask = 0x00000002u;
constexpr uint32_t kCompressorStatusEnabledMask = 0x00000001u;
constexpr uint32_t kCompressorStatusPrimedMask = 0x00000002u;
constexpr uint32_t kCompressorStatusActiveMask = 0x00000004u;
constexpr int kCompressorStatusDelayLevelLsb = 8;
constexpr int kCompressorStatusDelayLevelWidth = 16;
constexpr uint32_t kEffectStatusChorusEnabledMask = 0x00000001u;
constexpr uint32_t kEffectStatusReverbEnabledMask = 0x00000002u;
constexpr uint32_t kEffectStatusBusyMask = 0x00000004u;
constexpr uint32_t kEffectStatusChorusHistoryValidMask = 0x00000008u;
constexpr int kEffectStatusReverbValidLineMaskLsb = 4;
constexpr int kEffectStatusReverbValidLineMaskWidth = 8;
constexpr uint32_t kEffectStatusChorusConfigClampedMask = 0x00001000u;
constexpr uint32_t kEffectStatusReverbConfigClampedMask = 0x00002000u;
constexpr uint32_t kEffectStatusMixerConfigClampedMask = 0x00004000u;
constexpr int kReverbStatusPreDelayOccupancyLsb = 0;
constexpr int kReverbStatusPreDelayOccupancyWidth = 16;
constexpr int kReverbStatusValidLineMaskLsb = 16;
constexpr int kReverbStatusValidLineMaskWidth = 8;
constexpr int kPlatformErrorsSdErrorCodeLsb = 0;
constexpr int kPlatformErrorsSdErrorCodeWidth = 8;
constexpr int kPlatformErrorsLoaderErrorCodeLsb = 8;
constexpr int kPlatformErrorsLoaderErrorCodeWidth = 8;
constexpr int kPlatformErrorsLoaderStateLsb = 16;
constexpr int kPlatformErrorsLoaderStateWidth = 4;
constexpr int kPlatformErrorsSdRetryCountLsb = 20;
constexpr int kPlatformErrorsSdRetryCountWidth = 8;
constexpr int kPlatformErrorsSdRecoveryErrorCodeLsb = 28;
constexpr int kPlatformErrorsSdRecoveryErrorCodeWidth = 4;

constexpr uint32_t kQ15Full = 0x00007fffu;
constexpr uint32_t kFilterB0UnityQ214 = 0x00004000u;

}  // namespace render::regs
