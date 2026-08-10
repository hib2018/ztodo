# 設定・保存先・データ安全性

## TaskとProposal

Taskデータの保存先は次の優先順位で決まります。

1. `ZTODO_DATA_FILE`
2. `$XDG_DATA_HOME/ztodo/tasks.json`
3. `$HOME/.local/share/ztodo/tasks.json`

Proposalは`tasks.json`と同じディレクトリの`proposal.json`へ保存されます。

## Repository設定

1. `ZTODO_CONFIG_FILE`
2. `$XDG_CONFIG_HOME/ztodo/config.json`
3. `$HOME/.config/ztodo/config.json`

Repository設定にGitHub Tokenなどの秘密情報は保存しません。

## AIへの追加指示

1. `ZTODO_PROMPT_INSTRUCTIONS_FILE`
2. `$XDG_CONFIG_HOME/ztodo/prompt-instructions.txt`
3. `$HOME/.config/ztodo/prompt-instructions.txt`

上から順に最初に利用可能な場所を使用します。上書き用環境変数が未設定の場合、通常は`~/.config/ztodo/prompt-instructions.txt`へ保存され、実行したディレクトリによって保存先は変わりません。環境変数で上書きする場合も絶対パスを指定してください。

追加指示は最大64 KiBのUTF-8テキストです。制御文字を拒否し、検証成功後だけAtomic保存します。Tokenなどの秘密情報は記載しないでください。

## Atomic保存

Task、Proposal、Repository設定、AIへの追加指示は、一時ファイルへ完全に書き込んでから既存ファイルを置き換えます。途中失敗時に既存データを壊さないための仕組みです。

Proposalの承認では、全Taskをメモリへ追加してから`tasks.json`を一度だけ保存するため、一部だけが登録された状態を残しません。

## 主な上限

- Repository：20件
- AIへの追加指示：64 KiB
- ProposalのTask候補：20件
- Taskタイトル：200文字
- Issueタイトル：256文字
- Proposal概要：2000文字

## 一時データで試す

```sh
export ZTODO_DATA_FILE="$(mktemp -d)/tasks.json"
export ZTODO_CONFIG_FILE="$(mktemp -d)/config.json"
export ZTODO_PROMPT_INSTRUCTIONS_FILE="$(mktemp -d)/prompt-instructions.txt"

ztodo repo add owner/repository
ztodo add 一時的なTask
ztodo ls

unset ZTODO_DATA_FILE
unset ZTODO_CONFIG_FILE
unset ZTODO_PROMPT_INSTRUCTIONS_FILE
```

## トラブルシュート

`GitHub CLI failed`と表示された場合：

```sh
gh auth status
gh issue list --repo owner/repository
```

接続状態、認証、Repository名、アクセス権限を確認してください。

Repository未登録の場合：

```sh
ztodo repo add owner/repository
ztodo repo ls
```
