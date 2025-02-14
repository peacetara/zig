# Zig Examples

 * **Tetris** - A simple Tetris clone written in Zig. See
   [andrewrk/tetris](https://github.com/andrewrk/tetris).
 * **hello_world** - demonstration of a printing a single line to stdout.
   One version depends on libc; one does not.
 * **guess_number** - simple console game where you guess the number the
   computer is thinking of and it says higher or lower. No dependency on
   libc.
 * **cat** - implementation of the `cat` UNIX utility in Zig, with no dependency
   on libc.
 * **shared_library** - demonstration of building a shared library and generating
   a header file for interop with C code.
 * **mix_o_files** - how to mix .zig and .c files together as object files
 
## Run the examples
To run an example, [build](https://github.com/ziglang/zig#building-from-source) or [download](https://ziglang.org/download) the latest version of Zig and call `zig run` on the example's [root file](https://ziglang.org/documentation/master/#Root-Source-File).

`zig run hello_world/hello.zig`

Or build and run in 2 steps (from the hello_world directory):

``` shell
$ zig build-exe hello.zig
$ ./hello
Hello, world!
```
