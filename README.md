# ztodo

ztodoは、今日取り組む具体的な作業を管理する、小さなCLIタスク管理ツールです。Zigで実装されています。

中長期的な計画や大きな作業はGitHub Issuesなどに残し、ztodoでは「今から実行する作業」だけを扱うことを想定しています。現在は初期MVPであり、Taskは単純なJSONとして保存されます。

## 必要な環境

- Zig 0.16.0
- macOS、LinuxなどZigが動作する環境

Zigが利用できるか確認します。

```sh
zig version
```

`command not found: zig`と表示される場合、macOSではHomebrewなどを使ってインストールしてください。

```sh
brew install zig
```

## ビルド

リポジトリへ移動してビルドします。

```sh
cd /Users/hibik/dev/projects/ztodo
zig build
```

実行ファイルは次の場所に生成されます。

```text
zig-out/bin/ztodo
```

ビルドした実行ファイルは、プロジェクト内から直接実行できます。

```sh
./zig-out/bin/ztodo version
```

## どこからでも実行できるようにする

実行ファイルへのシンボリックリンクを、PATHに含まれる`~/.local/bin`へ作成します。

```sh
mkdir -p ~/.local/bin
ln -sfn /Users/hibik/dev/projects/ztodo/zig-out/bin/ztodo ~/.local/bin/ztodo
```

`~/.local/bin`がPATHに含まれていない場合は、次の設定を`~/.zshrc`へ追加します。

```sh
export PATH="$HOME/.local/bin:$PATH"
```

設定を現在のシェルへ反映します。

```sh
source ~/.zshrc
```

確認します。

```sh
ztodo version
```

```text
ztodo 0.1.0
```

このリポジトリを変更した後は、もう一度`zig build`を実行すればリンク先の実行ファイルも更新されます。

## 基本的な使い方

現在実装されているコマンドは次の7つです。短縮エイリアスやオプションはありません。

| コマンド | 実際の動作 |
| --- | --- |
| `ztodo add <title...>` | 1個以上のタイトル引数を空白で結合し、`todo`のTaskを追加する |
| `ztodo list` | `todo`と`done`をID昇順ですべて表示する |
| `ztodo done <id>` | 正の整数IDで指定したTaskを`done`にする |
| `ztodo delete <id>` | 指定したTaskを確認なしで完全に削除する |
| `ztodo clear` | 全Taskを確認なしで削除し、次のIDを`1`へ戻す |
| `ztodo help` | コマンド一覧、例、`clear`の警告を表示する |
| `ztodo version` | `ztodo 0.1.0`を表示する |

`list`、`help`、`version`、`clear`は追加の引数を受け付けません。`done`と`delete`はIDを1つだけ受け付けます。

### タスクを追加する

```sh
ztodo add "JSONファイルの読み込み処理を実装する"
```

```text
Added task 1: JSONファイルの読み込み処理を実装する
```

`add`は、後ろに渡された1個以上の引数を空白で結合してタイトルにします。タイトル全体を1引数として渡したい場合は引用符で囲めます。

そのため、通常のタイトルは引用符なしでも追加できます。

```sh
ztodo add JSONファイルの 読み込み処理を 実装する
```

上記は`JSONファイルの 読み込み処理を 実装する`という1つのタイトルとして保存されます。ただし、`*`、`?`、`$`、`;`、`&`、丸括弧など、シェルが解釈する文字を含む場合や、連続した空白をそのまま残したい場合は引用符で囲んでください。

空文字や空白だけのタイトルは登録できません。

### タスクを一覧表示する

```sh
ztodo list
```

```text
[ ] 1  JSONファイルの読み込み処理を実装する
[x] 2  READMEに使用例を追加する
```

- `[ ]`は未完了の`todo`
- `[x]`は完了した`done`
- 表示順はIDの昇順

タスクがない場合は次のように表示されます。

```text
No tasks.
```

### タスクを完了にする

一覧に表示されたIDを指定します。

```sh
ztodo done 1
```

```text
Completed task 1: JSONファイルの読み込み処理を実装する
```

すでに完了しているTaskにもう一度実行してもエラーにはなりません。

```text
Task 1 is already completed.
```

### タスクを削除する

```sh
ztodo delete 1
```

```text
Deleted task 1: JSONファイルの読み込み処理を実装する
```

削除前の確認はありません。`todo`と`done`のどちらも削除できます。一度使用したIDは、Taskを削除しても再利用されません。

### 全TaskとIDをリセットする

```sh
ztodo clear
```

```text
Cleared 3 tasks.
```

すべてのTaskを削除し、JSON内の`next_id`を`1`へ戻します。次に追加するTaskのIDは`1`になります。確認プロンプトはなく、元に戻せないため注意してください。Taskがない状態でも実行でき、その場合は`Cleared 0 tasks.`と表示されます。

### ヘルプを表示する

```sh
ztodo help
```

引数なしで実行した場合もヘルプが表示されます。

```sh
ztodo
```

### バージョンを表示する

```sh
ztodo version
```

## 一連の使用例

```sh
ztodo add "最初のタスク"
ztodo add "次のタスク"
ztodo list
ztodo done 1
ztodo list
ztodo delete 2
ztodo list
ztodo clear
```

## データの保存先

Taskは整形されたJSONファイルへ保存されます。保存先は次の優先順位で決まります。

1. 環境変数`ZTODO_DATA_FILE`で指定したパス
2. `$XDG_DATA_HOME/ztodo/tasks.json`
3. `$HOME/.local/share/ztodo/tasks.json`

保存先ディレクトリが存在しない場合は自動的に作成されます。保存時は一時ファイルを作成し、書き込み完了後に既存ファイルと置き換えます。

データファイルの例：

```json
{
  "schema_version": 1,
  "next_id": 2,
  "tasks": [
    {
      "id": 1,
      "title": "JSONファイルの読み込み処理を実装する",
      "status": "todo",
      "created_at": "2026-07-14T12:00:00Z"
    }
  ]
}
```

`created_at`はUTCのRFC 3339形式で保存されます。

## 一時データファイルを使う

通常のTaskへ影響を与えずに試したい場合は、`ZTODO_DATA_FILE`を指定します。

```sh
export ZTODO_DATA_FILE="$(mktemp -d)/tasks.json"

ztodo add "一時的なタスク"
ztodo list
```

現在のシェルで通常の保存先へ戻すには、環境変数を解除します。

```sh
unset ZTODO_DATA_FILE
```

## 開発時に直接実行する

インストールやシンボリックリンクを作成せず、ビルドランナーから実行することもできます。

```sh
zig build run -- add "タスクを追加する"
zig build run -- list
zig build run -- done 1
zig build run -- delete 1
zig build run -- clear
zig build run -- help
zig build run -- version
```

`--`より後ろの値がztodoの引数として渡されます。

## テスト

```sh
zig build test
```

テストでは実際のユーザー用データファイルを使用しません。

## よくあるエラー

### `command not found: ztodo`

次を順番に確認してください。

```sh
cd /Users/hibik/dev/projects/ztodo
zig build
ls -l ~/.local/bin/ztodo
echo "$PATH"
```

プロジェクト内からは、シンボリックリンクがなくても次のように実行できます。

```sh
./zig-out/bin/ztodo help
```

### 更新後も古いヘルプが表示される

ビルドし直し、グローバル実行用リンクを更新してから、zshのコマンドキャッシュを消去します。

```sh
cd /Users/hibik/dev/projects/ztodo
zig build
ln -sfn /Users/hibik/dev/projects/ztodo/zig-out/bin/ztodo ~/.local/bin/ztodo
rehash
```

実際に呼ばれるファイルとヘルプを確認します。

```sh
command -v ztodo
ztodo help
```

解決先は次のパスになります。

```text
/Users/hibik/.local/bin/ztodo
```

### `Error: task ... was not found.`

指定したIDのTaskが存在しません。`ztodo list`で現在のIDを確認してください。

### `Error: data file contains invalid JSON.`

保存データが壊れているか、正しいJSONではありません。ztodoは破損したファイルを空データとして上書きしません。ファイルをバックアップしてから内容を確認してください。

## 現在実装していない機能

- GitHub・AI連携
- Taskの編集、タグ、優先度、期限、説明欄
- 検索、フィルター、並び替えオプション
- TUI、GUI、通知、クラウド同期
- 設定ファイル、シェル補完、色付き表示
- SQLite、ファイルロック、自動マイグレーション

Taskの内容を変更したい場合は、現在のTaskを削除して新しく追加してください。
