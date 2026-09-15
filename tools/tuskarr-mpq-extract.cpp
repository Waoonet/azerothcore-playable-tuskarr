#include <StormLib.h>

#include <filesystem>
#include <iostream>

int main(int argc, char** argv)
{
    if (argc != 4)
    {
        std::cerr << "usage: tuskarr-mpq-extract <archive.mpq> <internal-path> <output-file>\n";
        return 64;
    }

    const char* archivePath = argv[1];
    const char* internalPath = argv[2];
    const char* outputPath = argv[3];

    HANDLE archive = nullptr;
    if (!SFileOpenArchive(archivePath, 0, MPQ_OPEN_READ_ONLY, &archive))
    {
        std::cerr << "ERROR: could not open MPQ: " << archivePath << "\n";
        return 10;
    }

    if (!SFileHasFile(archive, internalPath))
    {
        SFileCloseArchive(archive);
        return 4;
    }

    try
    {
        const std::filesystem::path out(outputPath);
        if (out.has_parent_path())
            std::filesystem::create_directories(out.parent_path());
    }
    catch (const std::exception& ex)
    {
        std::cerr << "ERROR: could not create output directory: " << ex.what() << "\n";
        SFileCloseArchive(archive);
        return 11;
    }

    if (!SFileExtractFile(archive, internalPath, outputPath, SFILE_OPEN_FROM_MPQ))
    {
        std::cerr << "ERROR: file exists but extraction failed: " << internalPath
                  << " from " << archivePath << "\n";
        SFileCloseArchive(archive);
        return 12;
    }

    SFileCloseArchive(archive);
    return 0;
}
