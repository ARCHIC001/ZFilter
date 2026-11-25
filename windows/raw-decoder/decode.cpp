#include "libraw/libraw.h"
#include <cstdio>
#include <cstring>
#include <memory>

int main(int argc, char **argv)
{
    if (argc != 3 && argc != 4)
    {
        std::fputs("Usage: zfilter-raw input.NEF output.tiff [half]\n", stderr);
        return 2;
    }

    auto raw = std::make_unique<LibRaw>();
    auto &options = raw->imgdata.params;
    options.use_camera_wb = 1;
    options.output_color = 1; // sRGB
    options.output_bps = 8;
    options.output_tiff = 1;
    options.half_size = argc == 4 && std::strcmp(argv[3], "half") == 0;

    const char *stage = "Open RAW";
    int status = raw->open_file(argv[1]);
    if (status == LIBRAW_SUCCESS)
    {
        stage = "Unpack sensor";
        status = raw->unpack();
    }
    if (status == LIBRAW_SUCCESS)
    {
        stage = "Render sensor";
        status = raw->dcraw_process();
    }
    if (status == LIBRAW_SUCCESS)
    {
        stage = "Write image";
        status = raw->dcraw_ppm_tiff_writer(argv[2]);
    }
    if (status != LIBRAW_SUCCESS)
    {
        std::fprintf(stderr, "%s: %s\n", stage, libraw_strerror(status));
        return 1;
    }
    return 0;
}
