// Prints sizes/offsets of the NVENC structs that Zig cannot translate (bitfields).
// Run: zig run tools/abi_check.c -lc -Ivendor/include
#include <stdio.h>
#include <stddef.h>
#include "ffnvcodec/nvEncodeAPI.h"
#define S(t) printf("%s size %zu\n", #t, sizeof(t))
#define O(t, f) printf("%s.%s %zu\n", #t, #f, offsetof(t, f))
int main(void) {
    S(NV_ENC_RC_PARAMS); O(NV_ENC_RC_PARAMS, rateControlMode); O(NV_ENC_RC_PARAMS, constQP); O(NV_ENC_RC_PARAMS, averageBitRate); O(NV_ENC_RC_PARAMS, maxBitRate); O(NV_ENC_RC_PARAMS, vbvBufferSize); O(NV_ENC_RC_PARAMS, minQP); O(NV_ENC_RC_PARAMS, targetQuality); O(NV_ENC_RC_PARAMS, lookaheadDepth);
    S(NV_ENC_CONFIG_HEVC); O(NV_ENC_CONFIG_HEVC, maxCUSize); O(NV_ENC_CONFIG_HEVC, idrPeriod); O(NV_ENC_CONFIG_HEVC, hevcVUIParameters); O(NV_ENC_CONFIG_HEVC, ltrTrustMode);
    S(NV_ENC_CODEC_CONFIG);
    S(NV_ENC_CONFIG); O(NV_ENC_CONFIG, profileGUID); O(NV_ENC_CONFIG, gopLength); O(NV_ENC_CONFIG, rcParams); O(NV_ENC_CONFIG, encodeCodecConfig);
    S(NV_ENC_INITIALIZE_PARAMS); O(NV_ENC_INITIALIZE_PARAMS, enablePTD); O(NV_ENC_INITIALIZE_PARAMS, privDataSize); O(NV_ENC_INITIALIZE_PARAMS, privData); O(NV_ENC_INITIALIZE_PARAMS, encodeConfig); O(NV_ENC_INITIALIZE_PARAMS, maxEncodeWidth); O(NV_ENC_INITIALIZE_PARAMS, tuningInfo); O(NV_ENC_INITIALIZE_PARAMS, bufferFormat);
    S(NV_ENC_PRESET_CONFIG); O(NV_ENC_PRESET_CONFIG, presetCfg);
    S(NV_ENC_PIC_PARAMS); O(NV_ENC_PIC_PARAMS, inputTimeStamp); O(NV_ENC_PIC_PARAMS, inputBuffer); O(NV_ENC_PIC_PARAMS, outputBitstream); O(NV_ENC_PIC_PARAMS, bufferFmt); O(NV_ENC_PIC_PARAMS, pictureStruct); O(NV_ENC_PIC_PARAMS, pictureType); O(NV_ENC_PIC_PARAMS, codecPicParams);
    S(NV_ENC_LOCK_BITSTREAM); O(NV_ENC_LOCK_BITSTREAM, outputBitstream); O(NV_ENC_LOCK_BITSTREAM, bitstreamSizeInBytes); O(NV_ENC_LOCK_BITSTREAM, outputTimeStamp); O(NV_ENC_LOCK_BITSTREAM, bitstreamBufferPtr); O(NV_ENC_LOCK_BITSTREAM, pictureType);
    S(NVENC_EXTERNAL_ME_HINT_COUNTS_PER_BLOCKTYPE); S(NV_ENC_QP);
    return 0;
}
