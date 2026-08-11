# 外部ツールとの連携

## Zsh補完

補完本体は`extras/zsh/`にあります。

```sh
source /path/to/ztodo/ztodo.plugin.zsh
autoload -Uz compinit && compinit
```

常に有効にする場合は`source`を`~/.zshrc`へ追加し、`exec zsh`で設定を反映します。Task操作ではIDとタイトルも補完候補へ表示されます。

## Herdr

Herdrの`~/.config/herdr/config.toml`へ次のカスタムコマンドを追加すると、`prefix+z`でztodoをポップアップとして起動できます。

```toml
[[keys.command]]
key = "prefix+z"
type = "popup"
command = "ztodo"
description = "Open ztodo in popup"
width = "90%"
height = "90%"
```

設定変更後は`herdr server reload-config`で反映します。ztodoを`q`で終了すると元のHerdrペインへ戻ります。

## GitHub CLI

ztodoはGitHub APIへ直接接続せず、認証とIssue取得を`gh`へ委譲します。
TUI起動時は登録RepositoryのOpen Issueについて番号、タイトル、Markdown本文を取得し、選択時の本文プレビューへ使用します。`o`では`gh issue view --web`を使って選択Issueをブラウザで開きます。

```sh
gh auth login
gh auth status
```

自動化環境でTokenが必要な場合だけ、現在のシェルへ一時的に設定します。

```sh
export GH_TOKEN="your-token"
gh auth status
unset GH_TOKEN
```

Tokenをシェル設定、`.env`、ztodoの設定やデータ、Git管理対象へ保存しないでください。
