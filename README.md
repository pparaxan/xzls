<div align="center">
<img src=".github/logo.svg" width=512>

<b>THIS PROJECT IS AI SLOP!!!<br>MOST COMMITS HERE ARE GENERATED VIA LLMs. DO NOT INSTALL IF YOU
DON'T SUPPORT WHAT XZLS IS DOING.</b>
<br>
<sub>Because of this, this project isn't allowed on Codeberg.</sub>

A fork of [zls](https://github.com/zigtools/zls), with changes the team can't (in time), and/or
won't implement in their LSP.

[![FCommunity](https://img.shields.io/badge/fluxer_community-%234641D9?style=for-the-badge&logo=fluxer&logoColor=white)](https://fluxer.gg/VKM258BV)
[![License](https://img.shields.io/badge/license-mit-%23C20018?style=for-the-badge)](https://codeberg.org/pparaxan/xzls/src/branch/master/LICENSE)
[![Zversion](https://img.shields.io/badge/zig_version-v0.17-%23F7A41D?style=for-the-badge&logo=zig&logoColor=white)](https://ziglang.org/download)

</div>

XZLS (xan!'s [fork of the] Zig Language Server) is a non-official implementation of the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol) for
[Zig](https://ziglang.org). It provides developers with [these IDE features](#features) in their editor.

## Build From Source

XZLS has no plans to target Zig `master`, only supporting stable versions.

To build XZLS from source, expecting you've `git clone`d this repository, run the following:
```bash
zig build -Doptimize=ReleaseSafe
```

Tagged XZLS releases doesn't follow Zig stable releases, so expect more updates and bug fixes per
Zig version.

## Install

Installing XZLS is very much different depending on the IDE, on how to install it for your specific
IDE, read [INSTALL.md](Install.md)!

## Features

XZLS supports most language features, including simple type function support, payload capture type
resolution, custom packages, and others. The following features are supported:

* Advanced Completions[^1]
* Hover
* Diagnostics and opt-in [build-on-save](https://zigtools.org/zls/guides/build-on-save/).
* Go to definition/declaration
* Workspace symbols and document symbols
* Find references and rename symbol
* Function reference-count CodeLens, resolved when the editor requests it[^2]
* Relative import updates when files or folders are renamed through the editor
* Document, selected-line, and on-type formatting based on `zig fmt`
* Semantic tokens highlighting
* Inlay hints
* Code actions & autofix
* Extract local initializer into a variable, extract scalar expression into a function,
  and inline single-use literal constants
* Comptime inspection
* Structural search & replace

And _wayy_ more.

## Why?
The point of this fork can be sumed up into four words, "I just wanna code". ZLS is developing at
a slow pace without features most LSP are calling a basic feature, to the point where it's actually
a bottleneck for you if you're the person who really code, and I'm not waiting months—up to years
just for my LSP to barely work as compared to what developers expect.

I just want to write code better and faster, not to complain to my LSP on why autocomplete doesn't
work.

It has pissed me off that badly that I just gave up and vibecoded an actual working, better LSP for
the language I love, and I'm releasing it to the public.

## Sponsor

XZLS is built ontop of ZLS, and if you'd want to help their development, consider donating through
[Open Collective](https://opencollective.com/zigtools) or
[GitHub Sponsors](https://github.com/sponsors/zigtools).

[^1]: When comparing to XLS, such as having postfix, payload unwrapping, et al.

[^2]: Requires editor CodeLens support. Opening the reference list also requires support for
    the `editor.action.showReferences` command. Run and debug actions are not provided.
