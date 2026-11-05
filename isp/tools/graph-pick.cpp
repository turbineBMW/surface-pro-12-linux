// Which graph does the HAL reader return for its video query key (fps 30,
// attributes 0, preview WxH bpp 8, no second stream)?
#include "Ipu75xaStaticGraphReaderAutogen.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
int main(int argc, char** argv) {
    FILE* f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); std::vector<char> d(ftell(f)); rewind(f);
    fread(d.data(), 1, d.size(), f); fclose(f);
    StaticReaderBinaryData bin; bin.data = d.data(); bin.size = d.size();
    StaticGraphReader r; if (r.Init(bin) != StaticGraphStatus::SG_OK) return 1;
    for (int i = 2; i + 1 < argc; i += 2) {
        GraphConfigurationKey key = {}; key.fps = 30; key.preview.width = atoi(argv[i]); key.preview.height = atoi(argv[i + 1]); key.preview.bpp = 8;
        IStaticGraphConfig* g = nullptr; int32_t id = 0;
        if (r.GetStaticGraphConfig(key, &g) == StaticGraphStatus::SG_OK && g) g->getGraphId(&id);
        printf("%sx%s -> graph %d\n", argv[i], argv[i + 1], id);
        delete g;
    }
    return 0;
}
