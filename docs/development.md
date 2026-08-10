# 開発ガイド

対象Zigバージョンは`build.zig.zon`の`minimum_zig_version`を正とします。

## 基本確認

```sh
zig fmt build.zig src
zig build test
zig build
```

開発中に直接実行する場合：

```sh
zig build run -- repo add owner/repository
zig build run -- issue
zig build run -- import
zig build run -- prop
zig build run -- ls
```

テストは通常のユーザーデータ、実GitHub認証、実Clipboardに依存しません。詳細な変更方針と完了条件はリポジトリルートの`AGENTS.md`を参照してください。
