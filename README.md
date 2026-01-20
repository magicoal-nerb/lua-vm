# lua-luau
*<b>A Lua 5.1 runtime made from the ground up in typed Luau</b>*<br>

## Usage
This VM uses the [Lune runtime](https://github.com/lune-org/lune) for running its tests, although any environment that uses [Luau](https://luau.org/) will work.
```bash
git clone "https://github.com/magicoal-nerb/lua-luau.git"
cd lua-luau
lune run tests/testRunner.luau 
```

## Features
* This project uses the traditional approach of making an AST that gets compiled into custom-made bytecode. All stages were manually written.
* New extensions to the base Lua 5.1 runtime, adds if-else expressions, continue, and compound assignments
* Written with being sandboxed in mind
* Since the runtime is in Luau, make sure that performance critical code remains outside of the main VM

## Planned features
* Optimizing bytecode through inlining, loop unrolling, call alignment, and global access chains to improve interpreter performance

## Pictures
![tests](./assets/tests.png)

<i>I originally made this to kill time with, but it eventually turned into a really fun deep-dive into my favorite programming language!!</i>

## Contributing
I'm not really looking for contributions for this project, since it's just a fun learning exercise. I just want to show the world this cool project I made. 
