# コマンドリファレンス

| コマンド | 動作 |
| --- | --- |
| `ztodo` | TUIを起動する |
| `ztodo repo add <owner/repo>` | Repositoryを登録する |
| `ztodo repo ls` | 登録済みRepositoryを表示する |
| `ztodo repo del <owner/repo>` | Repositoryを削除する |
| `ztodo issue [owner/repo]` | Issueを選び、AI向けプロンプトをコピーする |
| `ztodo prompt show` | AIへの追加指示を表示する |
| `ztodo prompt edit` | `$VISUAL`または`$EDITOR`で追加指示を編集する |
| `ztodo prompt preview` | サンプルIssueで完成プロンプトを表示する |
| `ztodo prompt reset` | 確認後に追加指示を削除する |
| `ztodo import` | ClipboardのProposal JSONを取り込む |
| `ztodo prop` | Proposalを編集・承認してTaskへ登録する |
| `ztodo add <title...>` | Taskを追加する |
| `ztodo ls` | 全Taskを表示する |
| `ztodo done <id>` | Taskを完了にする |
| `ztodo move <id> <position>` | Taskを指定した表示位置へ移動する |
| `ztodo del <id>` | Taskを確認なしで削除する |
| `ztodo clear` | 全Taskを削除し、次のIDを`1`へ戻す |
| `ztodo help` | ヘルプを表示する |
| `ztodo version` | バージョンを表示する |

`del`と`clear`は確認なしで実行され、元に戻せません。TUIでの削除と全削除は小文字の`y`による確認があります。

バージョン番号は`build.zig.zon`の`.version`で一元管理されます。CLIの`ztodo version`とTUIヘルプはビルド時に同じ値を参照します。
