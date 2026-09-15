#include <StormLib.h>

#include <filesystem>
#include <iostream>
#include <string>

int main(int argc, char** argv)
{
    if (argc != 3)
    {
        std::cerr << "usage: tuskarr-mpq-pack <source-root> <output.mpq>\n";
        return 64;
    }

    const std::filesystem::path root = std::filesystem::absolute(argv[1]);
    const std::filesystem::path archivePath = std::filesystem::absolute(argv[2]);

    if (!std::filesystem::is_directory(root))
    {
        std::cerr << "ERROR: source root is not a directory: " << root << "\n";
        return 10;
    }

    std::error_code ec;
    std::filesystem::create_directories(archivePath.parent_path(), ec);
    if (ec)
    {
        std::cerr << "ERROR: could not create archive parent directory: " << ec.message() << "\n";
        return 11;
    }

    std::filesystem::remove(archivePath, ec);
    ec.clear();

    std::size_t fileCount = 0;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(root))
        if (entry.is_regular_file())
            ++fileCount;

    if (fileCount == 0)
    {
        std::cerr << "ERROR: source root contains no files\n";
        return 12;
    }

    HANDLE archive = nullptr;
    DWORD maxFiles = static_cast<DWORD>(fileCount + 64);
    if (!SFileCreateArchive(archivePath.string().c_str(), MPQ_CREATE_ARCHIVE_V2, maxFiles, &archive))
    {
        std::cerr << "ERROR: SFileCreateArchive failed: " << archivePath << "\n";
        return 13;
    }

    std::size_t added = 0;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(root))
    {
        if (!entry.is_regular_file())
            continue;

        std::filesystem::path rel = std::filesystem::relative(entry.path(), root);
        std::string internal = rel.generic_string();
        for (char& ch : internal)
            if (ch == '/')
                ch = '\\';

        const DWORD flags = MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING;
        if (!SFileAddFileEx(archive,
                            entry.path().string().c_str(),
                            internal.c_str(),
                            flags,
                            MPQ_COMPRESSION_ZLIB,
                            MPQ_COMPRESSION_ZLIB))
        {
            std::cerr << "ERROR: could not add " << entry.path() << " as " << internal << "\n";
            SFileCloseArchive(archive);
            return 14;
        }
        ++added;
        std::cout << "ADD\t" << internal << "\n";
    }

    if (!SFileCloseArchive(archive))
    {
        std::cerr << "ERROR: SFileCloseArchive failed\n";
        return 15;
    }

    std::cout << "PASS: packed " << added << " files into " << archivePath << "\n";
    return 0;
}
