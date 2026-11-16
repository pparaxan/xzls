Do note that there needs to be a custom extension installed, as IDEs in general doesn't support
most LSP settings XZLS provides. Though it's still an WIP, so support is going to be limited.

<!--TODO: Add more IDEs later -->

Before you start, make sure you've downloaded the latest release of the XZLS for your platform
and architecture [here](https://github.com/pparaxan/xzls/releases/latest).

<details>
    <summary>VS Code</summary>

With the existing
[Zig extension](https://marketplace.visualstudio.com/items?itemName=ziglang.vscode-zig) installed,
replace the ZLS binary with XZLS' by doing `Ctrl + Shift + P` and opening your User Settings:
```json
{
  "zig.zls.path": "/path/to/xzls"
}
```

</details>

<details>
    <summary>Zed</summary>

With the existing [Zig extension](https://github.com/zed-extensions/zig) installed, replace the
ZLS binary with XZLS' by doing `Ctrl + Shift + P` and opening your settings file:
```json
{
  "lsp": {
    "zls": {
      "binary": {
        "allow_binary_download": false,
        "path": "/path/to/xzls"
      }
    },
  },
}
```

</details>
