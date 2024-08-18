# zigup

Download and manage zig compilers and ZLS versions.

Built-in support for Mach releases and ZLS

# Building

Zigup is currently built/tested using zig master (0.14.0-dev).

```sh
git clone https://github.com/galaxyshard/zigup
cd zigup

# Build in release mode
zig build -Doptimize=ReleaseSafe
```

# Usage

`<version>` may be any version number, `stable`, `master`, `<version>-mach`, `mach-latest`, `latest-installed`, or `stable-installed`

```sh
# fetch a compiler + zls version and set it as the default
zigup <version>
zigup 0.13.0
zigup 0.4.0-mach
zigup master
zigup mach-latest

# fetch a compiler + zls version (does not set it as default)
zigup fetch <version>
zigup fetch master

# print the default compiler version
zigup default

# set the default compiler
zigup default <version>
zigup default latest-installed
zigup default stable-installed

# list the installed compiler versions
zigup list

# Removes this compiler
zigup clean <version>

# Removes all compilers except latest-installed, latest installed stable, and any kept compilers
zigup clean outdated

# mark a compiler to keep
zigup keep <version>

# run a specific version of the compiler
zigup run <version> <args>...
```

# How the compilers are managed

Zigup stores each compiler and language server in a subdirectory of the installation directory, by default the data directory from [known-folders](https://github.com/ziglibs/known-folders).

Zigup can optionally symlink a "default" Zig/ZLS. On windows this will create an executable that forwards invocations to one of the `zig`/`zls` executables in the install directory.

Options can be configured via the following command line options:
```sh
# Single-run
zigup <command> --install-dir <DIR>
zigup <command> --zig-symlink <FILE_PATH>
zigup <command> --zls-symlink <FILE_PATH>

# Persist settings (saves in the default configuration directory from known-folders)
zigup set-install-dir <DIR>
zigup set-zig-symlink <FILE_PATH>
zigup set-zls-symlink <FILE_PATH>
```

# License

Copyright (c) Zigup contributers

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
