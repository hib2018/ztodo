# ztodo

ztodoは、「今から実行する作業」を管理する小さなCLIタスク管理ツールです。Zigで実装されています。

Markdownなどで中長期の作業を整理し、ztodoでは数十分から数時間程度の具体的なTaskを扱うことを想定しています。

## 必要な環境

- Zig 0.16.0
- macOS、LinuxなどZigが動作する環境
- GitHub Issue連携を使う場合は、認証済みの[GitHub CLI](https://cli.github.com/)

```sh
gh auth login
```

## ビルド

```sh
zig build
```

実行ファイルは`zig-out/bin/ztodo`に生成されます。

```sh
./zig-out/bin/ztodo help
```

PATHから実行する場合は、例えば`~/.local/bin`へリンクします。

```sh
mkdir -p ~/.local/bin
ln -sfn "$(pwd)/zig-out/bin/ztodo" ~/.local/bin/ztodo
```

### Zsh補完

Zsh補完は任意機能です。ztodo本体の実行には必要ありません。関連ファイルは`extras/zsh/`へまとめています。

`ztodo.plugin.zsh`を読み込むと、コマンドとTask IDをTab補完できます。

```sh
source /path/to/ztodo/ztodo.plugin.zsh
autoload -Uz compinit && compinit
```

例えば、次の位置でTabを押すと候補が表示されます。

```sh
ztodo <Tab>       # コマンド候補
ztodo done <Tab>  # Task IDとタイトル
ztodo del <Tab>   # Task IDとタイトル
```

常に有効にする場合は、1行目の`source`を`~/.zshrc`へ追加します。プラグインマネージャーを使う場合は、このリポジトリを通常のZshプラグインとして読み込めます。

通常のZsh補完だけでも動作します。別途`zsh-autocomplete`を導入している環境では、候補が入力中に自動表示されます。

## コマンド

| コマンド | 動作 |
| --- | --- |
| `ztodo add <title...>` | Taskを追加する |
| `ztodo ls` | 全TaskをID順に表示する |
| `ztodo done <id>` | Taskを完了にする |
| `ztodo del <id>` | Taskを確認なしで削除する |
| `ztodo clear` | 全Taskを削除し、次のIDを`1`へ戻す |
| `ztodo issue [owner/repo]` | GitHub Issueを選び、AI向けプロンプトを表示・コピーする |
| `ztodo import` | クリップボードのAI回答をProposalとして取り込む |
| `ztodo prop` | Proposalを編集・承認してTaskへ登録する |
| `ztodo help` | ヘルプを表示する |
| `ztodo version` | バージョンを表示する |

### Taskを操作する

```sh
ztodo add JSON保存処理を実装する
ztodo ls
ztodo done 1
ztodo del 1
```

一覧表示：

```text
[ ] 1  JSON保存処理を実装する
[x] 2  READMEを更新する
```

Taskは`id`、`title`、`status`だけを保持し、状態は`todo`または`done`です。空タイトルは登録できません。

`clear`と`del`には確認がなく、元に戻せません。

## GitHub IssueからAI向けプロンプトを作る

```sh
ztodo issue
```

現在のGitリポジトリで公開中のIssueが一覧表示されます。別のリポジトリを使う場合は`ztodo issue owner/repo`と指定します。番号を選ぶとIssue本文を含むProposal生成用プロンプトを標準出力へ表示し、クリップボードにもコピーします。`q`でキャンセルできます。

プロンプトを任意のAIへ貼り付け、返されたJSONをコピーして取り込みます。

```sh
ztodo import
ztodo prop
```

取り込み時にJSON形式とProposalの各項目を検証し、Taskが空の場合は拒否します。既存の`proposal.json`は上書きしません。

ztodo自身はOpenAI APIやGitHub APIを直接呼ばず、GitHubの認証と取得は`gh`へ任せます。macOSでは`pbcopy`と`pbpaste`、Linuxでは`wl-copy`・`wl-paste`または`xclip`を使用します。

## Proposalを編集・承認する

`proposal.json`が保存されている状態で実行します。

```sh
ztodo prop
```

```text
Issue #24: JSON保存処理を実装する
Repository: owner/ztodo

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

対話中の番号は`1`から始まります。

- `a`：Task候補を追加
- `e <n>`：タイトルを編集
- `d <n>`：`y`の確認後に削除
- `m <n>`：Task候補を指定位置へ移動
- `s`：現在のProposalを再表示
- `q`：編集を終了して承認確認へ進む

`q`の後にTask候補が表示され、`Approve? [y/N]`で小文字の`y`を入力するとTaskへ一括登録します。承認しなかった場合はProposalだけをAtomic保存し、後から再編集できます。入力が途中で終了した場合、編集内容は保存されません。

Task候補は最大20件、タイトルは最大200文字です。空タイトル、重複、不正なUTF-8、改行などの制御文字は拒否されます。

全Taskをメモリへ追加してから`tasks.json`を1回だけAtomic保存するため、一部だけが保存されることはありません。成功後は`proposal.json`を削除し、キャンセルやTask保存失敗時はProposalを残します。Task候補が空の場合は適用しません。

## データ保存

保存先は次の優先順位で決まります。

1. `ZTODO_DATA_FILE`
2. `$XDG_DATA_HOME/ztodo/tasks.json`
3. `$HOME/.local/share/ztodo/tasks.json`

Proposalは`tasks.json`と同じディレクトリの`proposal.json`へ保存されます。

```text
~/.local/share/ztodo/
├─ tasks.json
└─ proposal.json
```

Taskデータ：

```json
{
  "schema_version": 1,
  "next_id": 2,
  "tasks": [
    {
      "id": 1,
      "title": "JSON保存処理を実装する",
      "status": "todo"
    }
  ]
}
```

Proposalデータ：

```json
{
  "schema_version": 1,
  "source": {
    "provider": "github-cli",
    "repository": "owner/repo",
    "issue_number": 24,
    "issue_title": "JSON保存処理を実装する"
  },
  "summary": "TaskをJSONへ保存できるようにする",
  "completion_criteria": ["Taskを保存できる"],
  "tasks": [{ "title": "JSON保存処理を実装する" }],
  "excluded": [],
  "notes": []
}
```

どちらも一時ファイルへ完全に書き込んでから置き換えるAtomic保存を使用します。旧Taskデータの`created_at`は読み込み可能で、次回保存時に削除されます。

Proposalは`schema_version: 1`を使用します。バージョンなしの既存データはv1として読み込み、未対応バージョンや未知の項目は拒否します。Source、概要、各リスト項目は空欄・制御文字を許可しません。`provider`は最大50文字、`repository`は`owner/name`形式で最大200文字、Issueタイトルは最大256文字、概要は最大2000文字です。Taskは最大20件（タイトル200文字）、各リストは最大20件（1項目500文字）です。

## 一時データで試す

```sh
export ZTODO_DATA_FILE="$(mktemp -d)/tasks.json"

ztodo add 一時的なTask
ztodo ls

unset ZTODO_DATA_FILE
```

この場合、Proposalも同じ一時ディレクトリへ保存されます。

## 開発

```sh
zig build run -- add テストTask
zig build run -- ls
zig build run -- issue
zig build run -- import
zig build run -- prop
```

テスト：

```sh
zig build test --summary all
```

テストでは通常のユーザーデータを使用しません。

## 未実装

- Taskの編集、タグ、優先度、期限
- TUI、GUI、通知、クラウド同期
