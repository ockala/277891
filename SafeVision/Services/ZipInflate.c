// ZipInflate.c
//
// Raw-deflate 解压：系统 libz，inflateInit2(&strm, -15) + inflate()。
// 详见 ZipInflate.h。

#include "ZipInflate.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

uint8_t *SVZipInflateRawDeflate(
    const uint8_t *input,
    size_t inputLength,
    size_t expectedSize,
    size_t *outLength)
{
    *outLength = 0;
    if (expectedSize == 0) {
        // 空文件：返回一个 1 字节的有效分配，调用方按 0 长度取用。
        return (uint8_t *)calloc(1, 1);
    }
    if (input == NULL || inputLength == 0) {
        return NULL;
    }
    uint8_t *output = (uint8_t *)malloc(expectedSize);
    if (output == NULL) {
        return NULL;
    }
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in = (Bytef *)input;
    strm.avail_in = (uInt)inputLength;
    strm.next_out = output;
    strm.avail_out = (uInt)expectedSize;
    // -15 = 裸 deflate（无 zlib 头、无 Adler32），与 ZIP 的 method 8 一致。
    if (inflateInit2(&strm, -15) != Z_OK) {
        free(output);
        return NULL;
    }
    int ret = inflate(&strm, Z_FINISH);
    size_t produced = (size_t)strm.total_out;
    inflateEnd(&strm);
    if (ret != Z_STREAM_END || produced != expectedSize) {
        free(output);
        return NULL;
    }
    *outLength = produced;
    return output;
}
