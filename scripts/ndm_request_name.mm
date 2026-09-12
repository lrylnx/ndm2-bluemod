// ndm_request_name.mm — 就地改写 NeatDownloadRequest 里的「目标文件名」
//
// 为什么需要它（逆向结论，NDM2 v1.4 universal 实测）：
//   浏览器扩展的行协议里 **没有** 文件名字段。`3:` 也不是文件名——它是「第二路媒体流 URL」
//   （音视频分离时引擎用它合成 MKV）。把文件名塞进 `3:` 会让引擎切到音视频合成路径：
//   文件名被强制改成 xxx.mkv、分类变 Video，下载必定失败（Server Closed Connection Suddenly）。
//   App 真正用来决定落盘名 / 列表名 / 数据库 filename 列的是 C++
//   `NeatDownloadRequest::Url.FileName`，位于结构体偏移 296：
//       struct NeatDownloadRequest { NeatUrl Url; NeatUrl UrlAudio; int64 downloadID; ... }
//       struct NeatUrl { int Protocol; uint16 Port; bool Secure; std::string RawUrl, AbsoluteUrl,
//                        Scheme, QueryString, Path, AbsolutePath, AbsoluteHostPath, Host,
//                        OriginalHost, Fragment, User, Pass, FileName, mNonUnicodeRawUrl; }
//       → 8(头部) + 12×24 = 296
//
// 安全性：
//   * 写入前先做结构校验：短串 = data[0..22] + 长度字节[23]（最高位 0）；
//     长串 = ptr(0) / size(8) / cap|0x80..(16)。校验不通过（说明版本/偏移变了）直接放弃，
//     绝不写坏原请求。
//   * 赋值走 libc++ 的 std::string::operator=，与 App 同一份 libc++、同一套 ABI
//     （已实测：本机 clang 编出的 short/long 布局与 App 内存中完全一致），
//     堆分配/释放由标准库负责，任意长度文件名都安全。

#include <cstring>
#include <cstddef>
#include <string>

namespace {

constexpr std::size_t kFileNameOffset = 296;   // NeatDownloadRequest::Url.FileName
constexpr unsigned char kLongFlag = 0x80;      // 长度字节最高位 = 长串标志
constexpr unsigned char kMaxShortLen = 22;     // 短串最多放 22 个字符 + '\0'

bool IsPlausibleName(const char *s, std::size_t n) {
    if (s == nullptr || n == 0 || n > 1024) return false;
    for (std::size_t i = 0; i < n; ++i) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x20 || c == 0x7f) return false;   // 控制字符 → 说明结构不对
    }
    return true;
}

// 读取当前位置的字符串；结构不自洽则返回 false
bool ReadCurrent(unsigned char *p, std::string *out) {
    if (out == nullptr) return false;
    if ((p[23] & kLongFlag) != 0) {
        char *data = *reinterpret_cast<char **>(p);
        std::size_t size = *reinterpret_cast<std::size_t *>(p + 8);
        if (data == nullptr || size == 0 || size > 1024) return false;
        if (data[size] != '\0' || std::strlen(data) != size) return false;
        if (!IsPlausibleName(data, size)) return false;
        out->assign(data, size);
        return true;
    }
    unsigned char len = p[23];
    if (len == 0 || len > kMaxShortLen) return false;
    if (p[len] != '\0') return false;
    if (!IsPlausibleName(reinterpret_cast<char *>(p), len)) return false;
    out->assign(reinterpret_cast<char *>(p), len);
    return true;
}

}  // namespace

// 返回 0 成功；非 0 表示放弃（原请求未被改动）
extern "C" int ndm_set_request_file_name(void *request, const char *utf8_name) {
    if (request == nullptr || utf8_name == nullptr || *utf8_name == '\0') return -1;
    std::string want(utf8_name);
    if (want.size() > 1024) return -2;
    unsigned char *p = reinterpret_cast<unsigned char *>(request) + kFileNameOffset;
    std::string cur;
    if (!ReadCurrent(p, &cur)) return -3;          // 版本不符 / 偏移变了 → 不动它
    if (cur == want) return 0;                     // 已经是对的
    *reinterpret_cast<std::string *>(p) = want;    // 同一 ABI，交给标准库处理分配
    return 0;
}
