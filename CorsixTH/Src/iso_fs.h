/*
Copyright (c) 2010 Peter "Corsix" Cawley

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

#ifndef CORSIX_TH_ISO_FS_H_
#define CORSIX_TH_ISO_FS_H_

#include "config.h"

#include <cstdio>
#include <string>
#include <vector>

//! Layer for reading Theme Hospital files out of an .iso disk image
/*!
    An instance of this class can read files which contain an ISO 9660 file
    system (as described at http://alumnus.caltech.edu/~pje/iso9660.html and
    http://www.ecma-international.org/publications/files/ECMA-ST/Ecma-119.pdf)
    which are typically called iso disk images. Once given a disk image, it
    searches for the Theme Hospital data files, and can then be used to read
    these data files.
*/
class iso_filesystem {
 public:
  iso_filesystem();
  ~iso_filesystem();

  //! Set the character to be used between components in file paths
  void set_path_separator(char cSeparator);

  //! Load an .iso disk image and search for Theme Hospital data files
  /*!
      \param fRawFile A file handle of an .iso disk image. This handle must
        remain valid for as long as the IsoFilesystem instance exists, and
        is not automatically closed by the IsoFilesystem instance.
      \return true on success, false on failure - call getError() for reason
  */
  bool initialise(const char* path);

  //! Get the reason for the most recent failure
  /*!
      Can be called after initialise() or get_file_data() return false.
  */
  const char* get_error() const;

  using file_handle = int;

  //! Find a file in the loaded .iso disk image
  /*!
      If (and only if) the given file could not be found, then isHandleGood()
      will return false on the returned handle.
  */
  file_handle find_file(const char* sPath) const;

  //! Iterate all files of the .iso disk image within a given directory
  /*!
      \param sPath The directory to iterate
      \param fnCallback The function to be called for each file. The first
        parameter to this function is pCallbackData. The second is the name
        of a file which is in sPath.
      \param pCallbackData Opaque value to be called to fnCallback.
  */
  void visit_directory_files(const char* sPath,
                             void (*fnCallback)(void*, const char*,
                                                const char*),
                             void* pCallbackData) const;

  //! Test if a file handle from find_file() is good or is invalid
  static inline bool is_handle_good(file_handle x) { return x != 0; }

  //! Get the byte offset of the start of the file in the loaded .iso
  /*!
      \param iFile A file handle returned by find_file()
  */
  uint32_t get_file_start(file_handle iFile) const;

  //! Get the size (in bytes) of a file in the loaded .iso disk image
  /*!
      \param iFile A file handle returned by find_file()
  */
  uint32_t get_file_size(file_handle iFile) const;

  //! Get the contents of a file in the loaded .iso disk image
  /*!
      \param iFile A file handle returned by find_file()
      \param pBuffer The buffer to place the resulting data in
      \return true on success, false on failure - call getError() for reason
  */
  bool get_file_data(file_handle iFile, uint8_t* pBuffer);

 private:
  struct file_metadata {
    std::string path;
    uint32_t sector;
    uint32_t size;
  };

  std::FILE* raw_file;
  char* error;
  std::vector<file_metadata> files;
  long sector_size;
  char path_seperator;

  //! Free any memory in use
  void clear();

  //! Set the last error, printf-style
  void set_error(const char* sFormat, ...);

  //! Seek to a logical sector of the disk image
  bool seek_to_sector(uint32_t iSector);

  //! Read data from the disk image
  bool read_data(uint32_t iByteCount, uint8_t* pBuffer);

  //! Scan the given array of directory entries for a Theme Hospital file
  /*!
      \param pDirEnt Pointer to a padded array of ISO 9660 directory entries.
      \param dirEntsSize The number of bytes in the directory entry array.
      \param level The recursion level (used to prevent infinite loops upon
        maliciously-formed .iso disk images).
      \return 0 if no Theme Hospital files were found. 1 if the given array
        contains a Theme Hospital data file. 2 if the given array is the
        top-level Theme Hospital data directory. Other values otherwise.
  */
  int find_hosp_directory(const uint8_t* pDirEnt, const uint32_t dirEntsSize,
                          int level);

  //! Build the list of Theme Hospital data files
  /*!
      \param iSector The ordinal of a logical sector containing a padded
        array of ISO 9660 directory entries.
      \param dirEntsSize The number of bytes in the directory entry array.
      \param prefix The path name to prepend to filenames in the directory.
  */
  void build_file_lookup_table(uint32_t iSector, const uint32_t dirEntsSize,
                               const std::string& prefix);

  //! std:less like implementation for file_metadata. Based on the path.
  static bool file_metadata_less(const file_metadata& lhs,
                                 const file_metadata& rhs);
};

#endif
