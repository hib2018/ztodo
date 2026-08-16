# ztodo

ztodoは、GitHub Issueを「今から実行する具体的なTask」へ分解し、CLI/TUIで管理する小さなZigアプリケーションです。

```text
GitHub Issueを選択
  → AI向けプロンプトをコピー
  → Proposal JSONを取り込む
  → Taskを編集・承認
  → 実行・完了
```

## 特徴

- GitHub Issueを実行可能なTaskへ分解するワークフロー
- CLIとフルスクリーンTUIの両方からTaskを管理
- 利用者が選んだAIを使用し、AI APIの設定は不要
- AIへの追加指示を任意のエディタでカスタマイズ
- Task、Proposal、設定をAtomic保存
- GitHub認証はGitHub CLIへ、Clipboard操作はOSのコマンドへ委譲
- Tokenなどの秘密情報をztodoのデータへ保存しない

## 必要な環境

- Zig 0.16.0
- GitHub CLI（`gh`）
- macOSまたはLinux
- Clipboardコマンド
  - macOS：`pbcopy`、`pbpaste`
  - Linux：`wl-copy`、`wl-paste`または`xclip`

## Installation

```sh
git clone https://github.com/hib2018/ztodo.git
cd ztodo
zig build
```

実行ファイルは`zig-out/bin/ztodo`へ生成されます。

```sh
./zig-out/bin/ztodo help
```

PATHから実行する場合：

```sh
mkdir -p ~/.local/bin
ln -sfn "$(pwd)/zig-out/bin/ztodo" ~/.local/bin/ztodo
```

GitHub CLIを認証します。認証情報はztodoではなくGitHub CLIが管理します。

```sh
gh auth login
gh auth status
```

## Quick start

```sh
ztodo repo add owner/repository
ztodo issue
# コピーされたプロンプトを任意のAIへ貼り付ける
# AIが返したProposal JSONをClipboardへコピーする
ztodo import
ztodo prop
ztodo
```

TUIは左のTasksとActivity、右上のRepositories / Issues、右下のIssue本文で構成されます。Issueを選ぶと紐づくTaskだけを表示でき、手動追加Taskの紐付けや全Task表示への切り替えもできます。Activityには直近の操作と結果が表示され、フォーカスすると履歴領域が広がります。`Tab`でフォーカスを切り替え、現在使える操作は画面下部のHelpで確認できます。詳しくは[基本的な使い方](docs/guide.md#tuiを使う)を参照してください。

## Documentation

- [基本的な使い方](docs/guide.md)
- [コマンドリファレンス](docs/command-reference.md)
- [設定・保存先・データ安全性](docs/configuration.md)
- [外部ツールとの連携](docs/integrations.md)
- [開発ガイド](docs/development.md)

CLIの概要は`ztodo help`でも確認できます。
