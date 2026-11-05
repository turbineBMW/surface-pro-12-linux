// Load a static graph settings file with the HAL's own reader and resolve every
// configuration. Reports per graph id and failures. From Marco Glauser's
// check-graph.cpp (galaxybook6-ultra-camera, GPL-2.0), generalised.
#include "Ipu75xaStaticGraphReaderAutogen.h"
#include <cstdio>
#include <map>
#include <vector>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <graph settings bin>\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END);
    std::vector<char> d(ftell(f));
    rewind(f);
    if (fread(d.data(), 1, d.size(), f) != d.size()) { perror(argv[1]); return 2; }
    fclose(f);
    StaticReaderBinaryData bin; bin.data = d.data(); bin.size = d.size();
    StaticGraphReader r;
    if (r.Init(bin) != StaticGraphStatus::SG_OK) { fprintf(stderr, "Init failed: hash mismatch or malformed file\n"); return 1; }
    auto hdrs = r.GetGraphConfigurationHeaders();
    std::map<int, int> ok, links;
    int bad = 0;
    for (int i = 0; i < hdrs.first; i++) {
        GraphConfigurationKey key = hdrs.second[i].settingsKey;
        IStaticGraphConfig *g = nullptr; int32_t id = 0; GraphTopology *t = nullptr; int active = 0;
        if (r.GetStaticGraphConfig(key, &g) == StaticGraphStatus::SG_OK && g) {
            g->getGraphId(&id);
            g->getGraphTopology(&t);
            for (int j = 0; t && j < t->numOfLinks; j++) active += t->links[j]->isActive;
        }
        if (id == 0 || active == 0) {
            if (bad++ < 5) fprintf(stderr, "configuration %d (%ux%u video, %ux%u preview, %u fps): graph %d, %d active links\n",
                                   i, key.video.width, key.video.height, key.preview.width, key.preview.height, key.fps, id, active);
        } else { ok[id]++; links[id] += active; }
        delete g;
    }
    printf("%d configurations: ", hdrs.first);
    for (auto &kv : ok) printf("graph %d x%d (avg %d active links)  ", kv.first, kv.second, links[kv.first] / kv.second);
    printf("bad %d\n", bad);
    return bad ? 1 : 0;
}
