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

引数なしの`ztodo`はTUIを起動します。主要な操作は次のとおりです。

- `j` / `k`または`↓` / `↑`：Taskを選択
- `a` / `e`：追加・編集
- `Space`：完了状態を切り替え
- `d` / `C`：確認後に一件削除・全削除
- `K` / `J`：並べ替え
- `Tab`：Proposal画面
- `r`：Repositories画面
- `g`：Issues画面
- Repositories画面の`Space`：選択中Repositoryを開閉し、Issueを直下へ展開
- Repositories画面の`Enter`：選択中IssueのプロンプトをClipboardへコピー
- Repositories画面の`r`：選択中RepositoryのIssueを再取得
- プロンプト編集画面の`e`：外部エディタでAIへの追加指示を編集

全操作は[TUI操作設計](tui-design.md)を参照してください。
