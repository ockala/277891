// SafeVision-Bridging-Header.h
//
// Swift 与 C 混编的桥接头：只暴露 ZipInflate（raw-deflate 解压，
// 供 .svpreset.zip 导入使用）。头文件在 Services/ 下，用相对路径引入。

#import "Services/ZipInflate.h"
