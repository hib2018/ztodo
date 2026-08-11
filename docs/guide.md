# 基本的な使い方

## 1. Repositoryを登録する

Issueを取得するRepositoryを登録します。

```sh
ztodo repo add owner/repository-one
ztodo repo add owner/repository-two
ztodo repo ls
```

不要になったRepositoryは削除できます。

```sh
ztodo repo del owner/repository-two
```

Repositoryは`owner/name`形式で最大20件まで登録でき、重複は拒否されます。

## 2. GitHub Issueを選ぶ

登録した全RepositoryからOpen Issueを取得します。

```sh
ztodo issue
```

一つのRepositoryだけを一時的に対象にする場合：

```sh
ztodo issue owner/repository
```

Issueを選ぶと、Issue情報を含むAI向けプロンプトが表示され、Clipboardへコピーされます。

## 3. AIへの追加指示を編集する

固定のProposal JSON出力条件を保ったまま、Taskの言語や粒度、プロジェクト固有の方針を追加できます。

```sh
ztodo prompt edit     # $VISUAL、なければ$EDITORで編集
ztodo prompt show     # 追加指示だけを表示
ztodo prompt preview  # サンプルIssueを使って完成形を確認
ztodo prompt reset    # 確認後に追加指示を削除
```

例えばNeovimを使う場合は、シェルの設定へ次を追加します。

```sh
export VISUAL="nvim"
export EDITOR="$VISUAL"
```

`ztodo prompt edit`はカレントディレクトリに依存せず、追加指示ファイルを自動的に編集対象とします。初回は空の一時ファイルを開き、保存済みの指示がある場合はその内容をコピーしてから開きます。エディタ終了後に内容を検証し、成功した場合だけ正式な設定ファイルへAtomic保存します。

保存先や検証条件は[設定・保存先・データ安全性](configuration.md)を参照してください。

## 4. AIへプロンプトを貼り付ける

コピーされたプロンプトをCodexやChatGPTなど、任意のAIへ貼り付けます。固定プロンプトは次の条件をAIへ伝えます。

- 渡されたIssue情報だけを使用する
- GitHub、Web、ローカルファイルを追加調査しない
- コード変更やコマンド実行を行わない
- ztodoが検証できるProposal JSONだけを返す

AIが返したJSON全体をClipboardへコピーします。説明文やMarkdownのコードフェンスは含めません。

## 5. Proposalを取り込む

```sh
ztodo import
```

JSON形式、必須項目、文字数、重複、Task件数を検証し、成功した場合だけ`proposal.json`へAtomic保存します。Taskが空の場合や既存Proposalがある場合は取り込みません。

## 6. Proposalを編集・承認する

```sh
ztodo prop
```

編集コマンド：

- `a`：Task候補を追加
- `e <n>`：Task候補を編集
- `d <n>`：確認後に削除
- `m <n>`：指定位置へ移動
- `s`：再表示
- `q`：編集を終了して承認確認へ進む

承認確認では小文字の`y`だけが全Taskを登録してProposalを削除します。それ以外はTaskへ登録せず、編集済みProposalを保存します。入力が途中で終了した場合、編集内容は保存されません。

## 7. Taskを操作する

```sh
ztodo ls
ztodo add READMEを更新する
ztodo done 1
ztodo move 3 1
ztodo del 1
ztodo clear
```

## TUIを使う

引数なしの`ztodo`はTUIを起動します。左にTasks、右にRepositories / Issuesなどの補助画面、下部に現在使える操作を表示します。長いTask名、Issue名、Proposal候補は各ペイン内で折り返して表示します。登録済みRepositoryのOpen Issueは起動時に読み込まれるため、通常は`Space`ですぐに展開できます。取得に失敗した場合はエラーを表示し、`r`で再取得できます。

共通操作：

- `Tab`：Tasksと右ペインのフォーカスを切り替える
- `?`：フォーカス中の画面に対応した詳細ヘルプを開く
- `Esc`：popupまたは編集中の入力をキャンセルする
- `q`：TasksではTUIを終了し、右ペインでは一つ前へ戻る

タイトルやRepository名の入力popupでは、`←` / `→`でカーソルをUTF-8文字単位に移動できます。文字入力はカーソル位置へ挿入され、Backspaceはカーソル直前の一文字を削除します。

Tasks：

- `j` / `k`または`↓` / `↑`：Taskを選択
- `a` / `e`：追加・編集
- `Space`：完了状態を切り替え
- `d` / `C`：確認後に一件削除・全削除
- `K` / `J`：並べ替え
- `r`：Repositories / Issuesを右ペインに表示
- `p`：Proposalを右ペインに表示
- `g`：全RepositoryのOpen Issue一覧を右ペインに表示
- `P`：プロンプト編集を右ペインに表示

Repositories / Issues：

- `j` / `k`または`↓` / `↑`：Repositoryまたは展開済みIssueを選択
- `Space`：Repositoryを開閉し、Issueを直下へ展開
- `Enter`：選択IssueのAI向けプロンプトをClipboardへコピー
- `r`：選択RepositoryのIssueを再取得
- `a` / `d`：Repositoryを追加・確認後に削除

Proposal：

- `j` / `k`：Task候補を選択
- `a` / `e` / `d`：Task候補を追加・編集・確認後に削除
- `K` / `J`：並べ替え
- `i`：ClipboardからProposal JSONを取り込む
- `A`：確認後、ProposalをTaskへ適用する

全Issue一覧では`j` / `k`で選択し、`Enter`でAI向けプロンプトをClipboardへコピーします。プロンプト編集では`e`で`VISUAL`または`EDITOR`を起動します。

削除や承認は確認popupを表示し、小文字の`y`だけで確定します。それ以外の入力はキャンセルとして扱います。
