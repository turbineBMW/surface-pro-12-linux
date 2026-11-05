// Rewrite the graph-100002 settings of a Windows IPU75XA graph settings file
// (hash-stamped for HAL e5172cc) for the in-tree ISYS, which writes unpacked
// 16-bit RAW10 lines (ALIGN64(width*2)) where Windows' ISYS wrote packed 25
// pixels per 32 bytes. Compared against Intel's Linux OV13B10/OV08X40 graphs
// of the same release, the LBFF input feeder (ifd_pipe_1_3, 55223) holds:
//   word 10 [31:16] height; words 11 and 24 [31:16] stride;
//   word 19 | word 18 [31:24]: stride*height/256 (frame size, 256-B units);
//   word 36 [31:24]: 1 for packed input, 0 on Linux.
// Link 2 (ISYS -> LBFF) carries stride*height bytes. Intel's Linux graphs also
// stream links 7, 8 and 10 (mode 2) and set 0x00020000 in word 34 of the BBPS
// records at both ends of those links. Blocks shared by several settings are
// rewritten once. Graph 100003 and 100026 settings are left as they are.
//   linuxize-100002 <in.bin> <out.bin> [--windows-links]
#include "Ipu75xaStaticGraphAutogen.h"
#include "kernel_meta.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <vector>

template <class M> static int findKernel(uint16_t uuid) {
    for (uint32_t i = 0; i < M::count; i++) if (M::uuids[i] == uuid) return i;
    return -1;
}
template <class M> static uint32_t apiOffset(uint32_t i) {
    uint32_t off = 0; for (uint32_t k = 0; k < i; k++) off += M::apiSizes[k]; return off;
}
template <class M> static uint8_t* kernelApi(uint8_t* api, uint16_t uuid) {
    int i = findKernel<M>(uuid); return i < 0 ? nullptr : api + apiOffset<M>(i);
}
static uint32_t getWord(const uint8_t* r, int w) { uint32_t v; memcpy(&v, r + 2 + 4 * w, 4); return v; }
static void setWord(uint8_t* r, int w, uint32_t v) { memcpy(r + 2 + 4 * w, &v, 4); }

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <in.bin> <out.bin> [--windows-links]\n", argv[0]); return 2; }
    bool linuxLinks = !(argc > 3 && !strcmp(argv[3], "--windows-links"));
    FILE* f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); std::vector<uint8_t> d(ftell(f)); rewind(f);
    if (fread(d.data(), 1, d.size(), f) != d.size()) return 2; fclose(f);
    uint8_t* p = d.data();
    BinaryHeader hdr; memcpy(&hdr, p, sizeof hdr); p += 16;
    uint32_t pins[5]; memcpy(pins, p, 20); p += 20;
    uint32_t nd = 0; for (int i = 0; i < 5; i++) nd += pins[i];
    p += 16 * nd;
    uint32_t ng; memcpy(&ng, p, 4); p += 4 + 8 * ng;
    uint32_t nz; memcpy(&nz, p, 4); p += 4 + 8 * nz;
    auto* heads = reinterpret_cast<GraphConfigurationHeader*>(p);
    p += sizeof(GraphConfigurationHeader) * hdr.numberOfResolutions;
    auto* modes = reinterpret_cast<SensorMode*>(p);
    p += sizeof(SensorMode) * hdr.numberOfSensorModes;
    uint8_t* data = p;

    std::set<int32_t> done;
    unsigned settings = 0;
    for (uint32_t i = 0; i < hdr.numberOfResolutions; i++) {
        GraphConfigurationHeader& h = heads[i];
        if (h.graphId != 100002) continue;
        settings++;
        if (!done.insert(h.resConfigDataOffset).second) continue;
        GraphConfiguration100002 b; memcpy(&b, data + h.resConfigDataOffset, sizeof b);
        const StaticGraphKernelRes& in = b.isysOuterNodeConfiguration.resolutionInfos[0];
        const uint32_t width = in.output_width, height = in.output_height;
        const uint32_t stride = (width * 2 + 63) / 64 * 64;
        const uint32_t frame = stride * height;
        auto& lb = b.lbffBayerOuterNodeConfiguration;
        uint8_t* ifd = kernelApi<LbffBayerMeta>(lb.systemApiConfiguration, 55223);
        if (!ifd) { fprintf(stderr, "setting %u: no ifd kernel\n", h.settingId); return 1; }
        if ((getWord(ifd, 10) >> 16) != height) {
            fprintf(stderr, "setting %u: ifd height %u != isys %u\n", h.settingId, getWord(ifd, 10) >> 16, height);
            return 1;
        }
        const uint32_t winStride = getWord(ifd, 11) >> 16;
        if (b.linkConfigurations[2].bufferSize != winStride * height) {
            fprintf(stderr, "setting %u: link 2 %u != windows stride*height %u\n", h.settingId,
                    b.linkConfigurations[2].bufferSize, winStride * height);
            return 1;
        }
        setWord(ifd, 11, (getWord(ifd, 11) & 0xffffU) | (stride << 16));
        setWord(ifd, 24, (getWord(ifd, 24) & 0xffffU) | (stride << 16));
        const uint32_t units = frame / 256;
        setWord(ifd, 18, (getWord(ifd, 18) & 0x00ffffffU) | ((units & 0xffU) << 24));
        setWord(ifd, 19, units >> 8);
        setWord(ifd, 36, getWord(ifd, 36) & 0x00ffffffU);
        b.linkConfigurations[2].bufferSize = frame;
        if (linuxLinks) {
            // Links 7 (38648 -> 6907), 8 (59680 -> 57803) and 10 (20865 ->
            // 25579) stream in Intel's Linux graphs; their endpoint records
            // carry 0x00020000 in word 34.
            auto& bb = b.bbpsWithTnrOuterNodeConfiguration;
            for (uint16_t uuid : {25579, 20865, 57803, 6907})
                if (uint8_t* r = kernelApi<BbpsWithTnrMeta>(bb.systemApiConfiguration, uuid))
                    setWord(r, 34, getWord(r, 34) | 0x00020000U);
            for (uint16_t uuid : {38648, 59680})
                if (uint8_t* r = kernelApi<LbffBayerMeta>(lb.systemApiConfiguration, uuid))
                    setWord(r, 34, getWord(r, 34) | 0x00020000U);
            for (int l : {7, 8, 10}) b.linkConfigurations[l].streamingMode = 2;
        }
        memcpy(data + h.resConfigDataOffset, &b, sizeof b);
        if (done.size() == 1)
            printf("%ux%u: stride %u -> %u, frame %u (%u x 256), links %s\n", width, height, winStride, stride,
                   frame, units, linuxLinks ? "7/8/10 streaming + bbps flag" : "as Windows");
    }
    f = fopen(argv[2], "wb"); if (!f) { perror(argv[2]); return 2; }
    fwrite(d.data(), 1, d.size(), f); fclose(f);
    printf("%s: %u graph-100002 settings, %zu blocks rewritten\n", argv[2], settings, done.size());
    return 0;
}
