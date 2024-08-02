# zigup

Download and manage zig compilers.

# Building

Zigup is currently built/tested using zig master (0.14.0-dev).

```sh
git clone https://github.com/galaxyshard/zigup
cd zigup

# Build in debug mode
zig build

# Build in release mode: ReleaseSafe, ReleaseFast, ReleaseSmall
zig build -Doptimize=ReleaseSafe
```

# Usage

```
# fetch a compiler and set it as the default
zigup <version>
zigup 0.13.0
zigup 0.4.0-mach
zigup master
zigup mach-latest

# fetch a compiler only (do not set it as default)
zigup fetch <version>
zigup fetch master

# print the default compiler version
zigup default

# set the default compiler
zigup default <version>

# list the installed compiler versions
zigup list

# Removes this compiler
zigup clean <version>

# mark a compiler to keep (TODO: currently does nothing)
zigup keep <version>

# run a specific version of the compiler
zigup run <version> <args>...
```

# How the compilers are managed

zigup stores each compiler and language server in a subdirectory of the installation directory, by default the data directory from [known-folders](https://github.com/ziglibs/known-folders).

(TODO: temporarily removed) Zigup can optionally symlink a "default" Zig/ZLS. On windows this will create an executable that forwards invocations to one of the `zig`/`zls` executables in the install directory.

Options can be configured via the following command line options:
```
# Single-run
--install-dir DIR
# TODO: these do nothing
--zig-symlink FILE_PATH
--zls-symlink FILE_PATH

# Persist settings (saves in the default configuration directory from known-folders)
zigup set-install-dir DIR
zigup set-zig-symlink FILE_PATH
zigup set-zls-symlink FILE_PATH
```

# License

Copyright (c) Zigup contributers

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
