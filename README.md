# zigup

Download and manage zig compilers.

# How to Install

Go to https://marler8997.github.io/zigup and select your OS/Arch to get a download link and/or instructions to install via the command-line.

Otherwise, you can manually find and download/extract the applicable archive from [Releases](https://github.com/marler8997/zigup/releases). It will contain a single static binary named `zigup`, unless you're on Windows in which case it's 2 files, `zigup.exe` and `zigup.pdb`.

# Usage

```
# fetch a compiler and set it as the default
zigup <version>
zigup master
zigup 0.6.0

# fetch a compiler only (do not set it as default)
zigup fetch <version>
zigup fetch master

# print the default compiler version
zigup default

# set the default compiler
zigup default <version>

# list the installed compiler versions
zigup list

# clean compilers that are not the default, not master, and not marked to keep. when a version is specified, it will clean that version
zigup clean [<version>]

# mark a compiler to keep
zigup keep <version>

# run a specific version of the compiler
zigup run <version> <args>...
```

# How the compilers are managed

zigup stores each compiler in a global "install directory" in a versioned subdirectory.  On posix systems the "install directory" is `$HOME/zig` and on windows the install directory will be a directory named "zig" in the same directory as the "zigup.exe".

zigup makes the zig program available by creating an entry in a directory that occurs in the `PATH` environment variable.  On posix systems this entry is a symlink to one of the `zig` executables in the install directory.  On windows this is an executable that forwards invocations to one of the `zig` executables in the install directory.

Both the "install directory" and "path link" are configurable through command-line options `--install-dir` and `--path-link` respectively.
# Building

Run `zig build` to build, `zig build test` to test and install with:
```
# install to a bin directory with
cp zig-out/bin/zigup BIN_PATH
```

# Building Zigup

Zigup is currently built/tested using zig master (0.14.0-dev).

# TODO

* set/remove compiler in current environment without overriding the system-wide version.

# Dependencies

On linux and macos, zigup depends on `tar` to extract the compiler archive files (this may change in the future).

# License

Copyright (c) Zigup contributers

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
