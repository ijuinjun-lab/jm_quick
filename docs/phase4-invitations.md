# Phase 4: 本人登録によるイベント招待

## フローと権限

未登録メールへの招待は `eventInvitations` を pending で作成し、既存mail-apiで送る。
本人は有効なtokenを提示して招待正本のメールを取得する。編集不可のメール、
パスワード、確認欄を表示し、Firebase AuthクライアントSDKの
`createUserWithEmailAndPassword` で本人登録する。パスワードは確認欄と一致した場合だけ
Auth SDKへ渡す。Firebase側のpassword policy違反は画面に通知する。
Functions、Firestore、招待メール、アプリログにはパスワードを渡さない。

登録後は `acceptEventInvitation` を呼ぶ。Auth正本のメールと招待先をサーバーで照合する。
Firestore transaction内で招待の世代・状態・期限、招待者の現在権限、イベント、
対象者の既存権限を読み直し、eventAssignments有効化とaccepted化を同時に行う。
全体管理者は既存 `accessRoles.role=admin` のまま。event_managerへの任命は全体管理者だけ、
event_managerは自イベントのstaffを任命できる。staffからの昇格経路は設けない。
既存Authユーザーを追加した場合は、従来どおり即任命し、招待メールを送らない。

`prepareInvitationAccount` と新規招待用reset link発行を削除した。
Functionsは招待目的でAuthユーザーを作成・変更しない。

## 再開・取消・再招待

- Auth登録後に受諾だけ失敗しても、Authを削除したり再作成したりしない。
  ログイン済みなら同じ画面の「招待を受ける」で再試行する。
  再訪時にAuthがあればログインへ進み、同じUIDで受諾する。
  `email-already-in-use` でもログイン導線へ切り替える。
- 別メールでログインしている場合は受諾を拒否し、アカウント切替を案内する。
- tokenは32バイト乱数、FirestoreにはSHA-256 hashだけ。期限は7日。
- 再招待はtoken hashを更新し、旧tokenを無効化する。メール完了処理は
  pendingかつ送信時token hashと一致する世代だけを更新する。
- 取消が先に成立した招待から任命を作らない。受諾が先に成立した場合、
  後続の招待取消はchanged=falseになる。任命解除は既存の権限解除操作で行う。
- eventInvitationsのクライアント直接read/writeは全面拒否する。

## 検証範囲

本番Firestore/Auth/mail-api、実メール、Scheduler、Cloud Runの操作は行わない。
Functionsはfake Auth/mailとローカルFirestore Emulator、Flutterはmock/fakeで検証する。
外部socketを拒否する検証用preloadを使用したFunctions全テストも実施する。
ブラウザは本番entrypointを起動せず、実際の招待Widgetにfake Auth/APIを注入した
ローカルpreviewでPC/390pxを操作する。外部HTTPはPlaywrightで遮断し、フォントもローカル化する。
検証ログとスクリーンショットはGit対象外の `build/phase4-*`、`build/ui-preview/` に保存する。

検証コマンド（jm_quick配下だけ）:

- `git diff --check`
- `cd functions && npm run lint && npm test`
- `node --test functions/test/rules*.emulator.test.js`
- `flutter analyze --no-pub`
- `flutter test --no-pub --reporter expanded`
- `cd cloudrun/mail-api && npm test`
- `flutter build web --no-pub --no-web-resources-cdn`

## 境界・残る確認

AuthとFirestoreは単一transactionにできない。Auth登録済み・招待pendingは正常な中間状態として
再開できるようにする。Auth情報はサーバーで取得し、Firestore側の権限・状態はtransactionで保護する。
期限はtransactionのread完了後、書込みを積む直前にも再評価する。

メール欄の改変はSDK登録先へ反映しない。ただしFirebaseクライアントSDK自体への任意の呼出しを
UIで禁止することはできない。別メールのAuthアカウントを別途作っても、サーバーの招待照合により
当該イベント権限は取得できない。招待URLはメールを受け取った本人のcapabilityとして扱う。

本番Auth provider/password policy/承認済みdomain、App Check、mail-api実配送、
実端末のAuthセッションは今回確認していない。ローカル検証成功は本番疎通の証明ではない。

## 将来の本番反映後の最小ドライラン（今回は実行しない）

別途承認された反映後、専用イベントと承認済み検証者だけで行う。
1. 既存system adminから未登録event_managerを招待する。
2. 本人が受信リンクで登録・受諾し、担当イベントだけ表示されることを確認する。
3. event_managerから同イベントのstaffを招待し、同様に本人登録・受諾する。
4. staffが管理者設定へ入れず、他イベントへアクセスできないことを確認する。
5. 招待取消・再招待の旧リンク無効・登録済みユーザーの即任命を確認する。
6. 初期設定で中断した検証者が同じURLからログインして受諾できることを確認する。
7. 検証用任命は既存の解除UIで解除する。CSV取込、当選メール、受付、Schedulerは操作しない。

## 今回の検証結果

- 開始/終了: main、HEAD `e30957747d5e50044dcf66aaae8906d77c0afa7e`。commit/push/deployなし。
- Functions lint成功。Functions全932件成功・skip 0（外部socket拒否付きの全件再実行も成功）。
- Rules Emulator全160件成功・skip 0（Functions全件にも含まれる）。
- Flutter analyze指摘0、Flutter全507件成功。
- mail-api全21件成功。Web release build成功。
- 招待+public_boundary組合せ27件成功。全件実行でも既存rate-limitの間欠失敗は再現せず、原因は未確定。
  rate-limit本番ロジックと既存public_boundaryテストの期待値は変更していない。
- PC 1280px/390pxで各7場面、計14場面の実Chromium操作成功。
  未登録者の入力→登録→受諾完了、登録済みログイン→受諾、ログイン済み受諾を操作。
  招待中、期限切れ、取消済みも表示確認。最終ブラウザ実行は外部HTTP要求0・page error 0。
  初期検証で要求された外部フォントは通信前に遮断し、最終previewではローカルフォントを使用した。
- 追加内容のsecret形式・非fixtureメール検査で指摘0。git diff --check指摘0。
- ローカル検証の起動プロセスは終了済み。元から動いていたプロセスには操作していない。

## 最終差分ファイル（既存Phase 4差分を含む）

- `docs/phase4-invitations.md`
- `functions/confirmed/invitation_api.js`
- `functions/test/event_invitations.emulator.test.js`
- `lib/confirmed/invitation_page.dart`
- `lib/confirmed/invitation_service.dart`
- `test/auth_registration_test.dart`
- `test/phase4_invitation_test.dart`
- `firestore.rules`
- `functions/index.js`
- `functions/test/confirmed_callable_structure.test.js`
- `functions/test/confirmed_no_dedupe_sources.test.js`
- `functions/test/event_assignments_api.emulator.test.js`
- `functions/test/rules.final_closure.emulator.test.js`
- `lib/confirmed/assignment_pages.dart`
- `lib/confirmed/assignment_service.dart`
- `lib/confirmed/auth_client.dart`
- `lib/main.dart`
- `test/confirmed_auth_test.dart`
- `test/phase3_roles_test.dart`

開始時の未追跡 `lib/confirmed/external_navigation.dart`、`external_navigation_stub.dart`、`external_navigation_web.dart` は、reset画面への唯一の利用箇所を除去したため削除した。
