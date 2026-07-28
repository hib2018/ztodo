# ztodo

ztodoは、GitHub Issueを「今から実行する具体的なTask」へ分解し、管理する小さなCLIツールです。Zigで実装されています。

基本の流れは次のとおりです。

```text
Repositoryを登録
  → GitHub Issueを選択
  → プロンプトをAIへ貼り付け
  → AIのProposal JSONを取り込む
  → Proposalを編集・承認
  → Taskを実行・完了
```

## 必要な環境

- Zig 0.16.0
- GitHub CLI（`gh`）
- macOSまたはLinux
- クリップボードコマンド
  - macOS：`pbcopy`、`pbpaste`
  - Linux：`wl-copy`、`wl-paste`または`xclip`

ztodo自身はGitHub APIやAI APIを直接呼びません。GitHubの取得と認証は`gh`へ、Task分解は利用者が選んだAIへ任せます。

## セットアップ

### 1. ビルド

```sh
zig build
```

実行ファイルは`zig-out/bin/ztodo`に生成されます。

```sh
./zig-out/bin/ztodo help
```

PATHから実行する場合：

```sh
mkdir -p ~/.local/bin
ln -sfn "$(pwd)/zig-out/bin/ztodo" ~/.local/bin/ztodo
```

### 2. GitHub認証

通常はGitHub CLIのブラウザ認証を使用します。

```sh
gh auth login
gh auth status
```

認証情報はztodoではなく、GitHub CLIが管理します。

自動化環境などでTokenが必要な場合だけ、現在のシェルへ一時的に設定します。

```sh
export GH_TOKEN="your-token"
gh auth status
unset GH_TOKEN
```

`GITHUB_TOKEN`も利用できますが、両方ある場合は`GH_TOKEN`が優先されます。Tokenを`.zshrc`、`.env`、README、ztodoのデータへ保存したり、Gitへコミットしたりしないでください。

## 基本的な使い方

### 1. Repositoryを登録する

Issueを取得するRepositoryを登録します。

```sh
ztodo repo add owner/repository-one
ztodo repo add owner/repository-two
```

登録内容を確認します。

```sh
ztodo repo ls
```

不要になったRepositoryは削除できます。

```sh
ztodo repo del owner/repository-two
```

Repositoryは`owner/name`形式で最大20件まで登録でき、重複は拒否されます。設定は`~/.config/ztodo/config.json`へAtomic保存され、Tokenなどの秘密情報は含みません。

### 2. GitHub Issueを選ぶ

登録した全RepositoryからOpen Issueを取得します。

```sh
ztodo issue
```

```text
Open GitHub Issues

1. owner/repository-one#25 ロードマップを整理する
2. owner/repository-two#10 TUIを実装する

Select an issue number (q to cancel):
```

一つのRepositoryだけを一時的に対象にする場合：

```sh
ztodo issue owner/repository
```

Issueを選ぶと、Issue情報を含むAI向けプロンプトが表示され、クリップボードへコピーされます。

### 3. AIへプロンプトを貼り付ける

コピーされたプロンプトをCodexやChatGPTなどへ貼り付けます。

プロンプトはAIに次の制約を伝えます。

- 渡されたIssue情報だけを使用する
- GitHub、Web、ローカルファイルを追加調査しない
- コード変更やコマンド実行を行わない
- ztodoが検証できるProposal JSONだけを返す

AIが返したJSON全体をクリップボードへコピーします。説明文やMarkdownのコードフェンスは含めません。

### 4. AIの回答を取り込む

```sh
ztodo import
```

JSON形式、必須項目、文字数、重複、Task件数を検証し、成功した場合だけ`proposal.json`へAtomic保存します。Taskが空の場合や、既存Proposalがある場合は取り込みません。

### 5. Proposalを編集・承認する

```sh
ztodo prop
```

```text
Issue #24: JSON保存処理を実装する
Repository: owner/repository

1. 保存形式を定義する
2. JSON読み込み処理を実装する

Commands:
  a       Add
  e <n>   Edit
  d <n>   Delete
  m <n>   Move
  s       Show
  q       Finish editing and review for approval

>
```

操作：

- `a`：Task候補を追加
- `e <n>`：Task候補を編集
- `d <n>`：確認後に削除
- `m <n>`：指定位置へ移動
- `s`：再表示
- `q`：編集を終了して承認確認へ進む

`q`の後に次の確認が表示されます。

```text
Approve? [y/N]
```

- `y`：全Taskを一括登録し、Proposalを削除
- それ以外：Taskへ登録せず、編集済みProposalを保存

入力が途中で終了した場合、編集内容は保存されません。

### 6. Taskを操作する

```sh
# 一覧
ztodo ls

# Taskを追加
ztodo add READMEを更新する

# 完了
ztodo done 1

# 削除
ztodo del 1

# 全Taskを削除してIDを1へ戻す
ztodo clear
```

一覧表示：

```text
[ ] 1  JSON保存処理を実装する
[x] 2  READMEを更新する
```

`del`と`clear`には確認がなく、元に戻せません。

## コマンド一覧

| コマンド | 動作 |
| --- | --- |
| `ztodo repo add <owner/repo>` | Repositoryを登録する |
| `ztodo repo ls` | 登録済みRepositoryを表示する |
| `ztodo repo del <owner/repo>` | Repositoryを削除する |
| `ztodo issue [owner/repo]` | Issueを選び、AI向けプロンプトをコピーする |
| `ztodo import` | クリップボードのProposal JSONを取り込む |
| `ztodo prop` | Proposalを編集・承認してTaskへ登録する |
| `ztodo add <title...>` | Taskを追加する |
| `ztodo ls` | 全Taskを表示する |
| `ztodo done <id>` | Taskを完了にする |
| `ztodo del <id>` | Taskを確認なしで削除する |
| `ztodo clear` | 全Taskを削除し、次のIDを`1`へ戻す |
| `ztodo help` | ヘルプを表示する |
| `ztodo version` | バージョンを表示する |

## Zsh補完（任意）

Zsh補完はztodo本体の実行には必要ありません。補完本体は`extras/zsh/`にあります。

```sh
source /path/to/ztodo/ztodo.plugin.zsh
autoload -Uz compinit && compinit
```

```sh
ztodo <Tab>       # コマンド候補
ztodo repo <Tab>  # Repository管理コマンド
ztodo done <Tab>  # Task IDとタイトル
ztodo del <Tab>   # Task IDとタイトル
```

常に有効にする場合は、`source`を`~/.zshrc`へ追加します。`zsh-autocomplete`を導入している環境では、候補が入力中に自動表示されます。

設定を反映し直す場合：

```sh
exec zsh
```

## エラー時の確認

`GitHub CLI failed`と表示された場合：

```sh
gh auth status
gh issue list --repo owner/repository
```

ztodoは`gh`が返した診断文も表示します。接続状態、認証、Repository名、アクセス権限を確認してください。

Repository未登録の場合：

```sh
ztodo repo add owner/repository
ztodo repo ls
```

## データと設定

Taskデータの保存先：

1. `ZTODO_DATA_FILE`
2. `$XDG_DATA_HOME/ztodo/tasks.json`
3. `$HOME/.local/share/ztodo/tasks.json`

Proposalは`tasks.json`と同じディレクトリの`proposal.json`へ保存されます。

Repository設定の保存先：

1. `ZTODO_CONFIG_FILE`
2. `$XDG_CONFIG_HOME/ztodo/config.json`
3. `$HOME/.config/ztodo/config.json`

TaskとProposalは一時ファイルへ完全に書き込んでから置き換えるAtomic保存を使用します。Proposalの承認では、全Taskをメモリへ追加してから`tasks.json`を一度だけ保存するため、一部だけが登録された状態を残しません。

主な上限：

- Repository：20件
- ProposalのTask候補：20件
- Taskタイトル：200文字
- Issueタイトル：256文字
- Proposal概要：2000文字

## 一時データで試す

```sh
export ZTODO_DATA_FILE="$(mktemp -d)/tasks.json"
export ZTODO_CONFIG_FILE="$(mktemp -d)/config.json"

ztodo repo add owner/repository
ztodo add 一時的なTask
ztodo ls

unset ZTODO_DATA_FILE
unset ZTODO_CONFIG_FILE
```

## 開発

```sh
zig build
zig build test --summary all
```

開発時に直接実行する場合：

```sh
zig build run -- repo add owner/repository
zig build run -- issue
zig build run -- import
zig build run -- prop
zig build run -- ls
```

テストでは通常のユーザーデータを使用しません。

## 未実装

- Taskの編集、タグ、優先度、期限
- TUI、メニューバー、通知、クラウド同期
