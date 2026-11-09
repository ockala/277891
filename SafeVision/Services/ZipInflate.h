// ZipInflate.h
//
// Raw-deflate 解压（供 .svpreset.zip 包使用）。
// 系统自带的 libz（<zlib.h>）：ZIP 里的 deflate 条目是裸 deflate 流
//（无 zlib 头、无 Adler32），必须用 inflateInit2(&strm, -15)。
// Compression 框架只提供 zlib 流接口，之前用“补 zlib 头 + 假 Adler32”
// 的 trick 赌解码器报错时输出还在，实测会丢掉全部输出，因此改走 libz。

#ifndef ZipInflate_h
#define ZipInflate_h

#include <stddef.h>
#include <stdint.h>

/// 解压裸 deflate 数据。
/// - 参数 input：压缩数据；inputLength：压缩数据长度；
///   expectedSize：期望的解压后长度（ZIP 中央目录给出）。
/// - 返回：malloc 分配的解压后数据（调用方负责 free），失败返回 NULL；
///   成功时 *outLength == expectedSize。
uint8_t * _Nullable SVZipInflateRawDeflate(
    const uint8_t * _Nonnull input,
    size_t inputLength,
    size_t expectedSize,
    size_t * _Nonnull outLength);

#endif /* ZipInflate_h */
