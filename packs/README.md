# Packs

Games (and later utilities) that people install from Zephydian's Library. Each folder is one pack:

```
packs/games/<id>/        manifest.json, main.js, icon.png, assets/
packs/utilities/<id>/    (later SDK versions)
```

How to make one, test it and submit it: [docs/PACKS.md](../docs/PACKS.md).

Check your pack before opening a pull request:

```sh
swift scripts/packs.swift check packs
```
