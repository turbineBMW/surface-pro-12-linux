// Dump the graph-100002 block of one setting of an IPU75XA static graph file
// (HAL e5172cc layout): node stream ids / tuning modes, link configs, the LBFF
// input feeder words and a few flag bytes. For comparing the Windows files
// against Intel's Linux ones before rewriting the ISYS input layout.
//   graph-dump <file.bin> [preview_w preview_h]
#include "Ipu75xaStaticGraphAutogen.h"
#include "kernel_meta.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
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
static void res(const char* n, const StaticGraphKernelRes& r) {
    printf("    %s in %dx%d crop(%d,%d,%d,%d) out %dx%d crop(%d,%d,%d,%d)\n", n, r.input_width, r.input_height,
           r.input_crop.left, r.input_crop.top, r.input_crop.right, r.input_crop.bottom,
           r.output_width, r.output_height, r.output_crop.left, r.output_crop.top, r.output_crop.right, r.output_crop.bottom);
}

int main(int argc, char** argv) {
    if (argc < 2) return 2;
    FILE* f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); std::vector<uint8_t> d(ftell(f)); rewind(f);
    if (fread(d.data(), 1, d.size(), f) != d.size()) return 2; fclose(f);
    uint32_t pw = argc > 2 ? atoi(argv[2]) : 1920, ph = argc > 3 ? atoi(argv[3]) : 1080;
    const uint8_t* p = d.data();
    BinaryHeader hdr; memcpy(&hdr, p, sizeof hdr); p += 16;
    uint32_t pins[5]; memcpy(pins, p, 20); p += 20;
    uint32_t nd = 0; for (int i = 0; i < 5; i++) nd += pins[i];
    p += 16 * nd;
    uint32_t ng; memcpy(&ng, p, 4); p += 4 + 8 * ng;
    uint32_t nz; memcpy(&nz, p, 4); p += 4 + 8 * nz;
    const auto* heads = reinterpret_cast<const GraphConfigurationHeader*>(p);
    p += sizeof(GraphConfigurationHeader) * hdr.numberOfResolutions;
    const auto* modes = reinterpret_cast<const SensorMode*>(p);
    p += sizeof(SensorMode) * hdr.numberOfSensorModes;
    const uint8_t* data = p;
    printf("%s: %u settings, header %zu B, block100002 %zu B, lbff api %zu, bbps api %zu\n", argv[1],
           hdr.numberOfResolutions, sizeof(GraphConfigurationHeader), sizeof(GraphConfiguration100002),
           sizeof(LbffBayerOuterNodeConfiguration::systemApiConfiguration), sizeof(BbpsWithTnrOuterNodeConfiguration::systemApiConfiguration));
    for (uint32_t i = 0; i < hdr.numberOfResolutions; i++) {
        const auto& h = heads[i];
        if (h.graphId != 100002 || h.settingsKey.preview.width != pw || h.settingsKey.preview.height != ph ||
            h.settingsKey.video.width != 0 || h.settingsKey.fps != 30) continue;
        const SensorMode& sm = modes[h.sensorModeIndex];
        printf("  setting %u: attr 0x%x preview %ux%u bpp %u, sensor mode %ux%u, offset %d\n", h.settingId,
               h.settingsKey.attributes, pw, ph, h.settingsKey.preview.bpp, sm.croppedImageWidth, sm.croppedImageHeight, h.resConfigDataOffset);
        GraphConfiguration100002 b; memcpy(&b, data + h.resConfigDataOffset, sizeof b);
        const auto& s = b.sinkMappingConfiguration;
        printf("    sinks: preview %u video %u ppv %u stills %u thumb %u\n", s.preview, s.video, s.postProcessingVideo, s.stills, s.thumbnail);
        printf("    streamId isys %u lbff %u bbps %u; tuningMode %u %u %u\n", b.isysOuterNodeConfiguration.streamId,
               b.lbffBayerOuterNodeConfiguration.streamId, b.bbpsWithTnrOuterNodeConfiguration.streamId,
               b.isysOuterNodeConfiguration.tuningMode, b.lbffBayerOuterNodeConfiguration.tuningMode, b.bbpsWithTnrOuterNodeConfiguration.tuningMode);
        res("isys res[0]", b.isysOuterNodeConfiguration.resolutionInfos[0]);
        printf("    isys bpp %u/%u\n", b.isysOuterNodeConfiguration.bppInfos[0].input_bpp, b.isysOuterNodeConfiguration.bppInfos[0].output_bpp);
        auto& lb = b.lbffBayerOuterNodeConfiguration;
        res("lbff res[0]", lb.resolutionInfos[0]);
        res("lbff hist[0]", lb.resolutionHistories[0]);
        int ifdi = findKernel<LbffBayerMeta>(55223);
        printf("    ifd bpp %u/%u\n", lb.bppInfos[ifdi].input_bpp, lb.bppInfos[ifdi].output_bpp);
        uint8_t* ifd = kernelApi<LbffBayerMeta>(lb.systemApiConfiguration, 55223);
        printf("    ifd api size %u, hdr %02x %02x, words:", LbffBayerMeta::apiSizes[ifdi], ifd[0], ifd[1]);
        for (uint32_t w = 0; w < (LbffBayerMeta::apiSizes[ifdi] - 2) / 4; w++) printf(" %u:%08x", w, getWord(ifd, w));
        printf("\n    flag bytes:");
        for (uint16_t u : {11700, 10326, 62344, 55073, 15021}) { uint8_t* r = kernelApi<LbffBayerMeta>(lb.systemApiConfiguration, u); printf(" %u:[%02x %02x %02x %02x %02x %02x]", u, r[0], r[1], r[2], r[3], r[4], r[5]); }
        auto& bb = b.bbpsWithTnrOuterNodeConfiguration;
        printf("\n    bbps:");
        for (uint16_t u : {25579, 20865}) { uint8_t* r = kernelApi<BbpsWithTnrMeta>(bb.systemApiConfiguration, u); printf(" %u w34=%08x", u, getWord(r, 34)); }
        printf("\n    links:");
        for (int l = 0; l < 15; l++) printf(" %d:%u/%u", l, b.linkConfigurations[l].bufferSize, b.linkConfigurations[l].streamingMode);
        printf("\n");
        break;
    }
    return 0;
}
