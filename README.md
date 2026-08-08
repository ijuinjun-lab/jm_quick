# JM Quick 実使用テスト版

スタッフが案内メール、参加確定、リコンファーム、QR受付、当日参加登録を一通り体験するFlutter Web + Firestoreプロトタイプです。

## 画面

- `/admin`：イベント一覧
- `/admin/events/{eventId}`：イベント個別管理、当日参加用QR、メール送信、リアルタイム集計
- `/p/{participantId}?publicId=...`：本人専用マイページ
- `/reception?eventId=...&participantId=...&publicId=...`：受付
- `/e/{eventId}/walk-in`：イベント専用QRから開く本人入力用の当日参加登録

イベント個別管理画面の「当日参加用QRを表示」から、本人入力ページのQRを表示できます。

## メール設定

メールはFlutterから直接送らず、`asia-northeast1` のFirebase Callable Function
`sendParticipantMail`を経由して、SippoPETと同じSendGrid構成の共通Cloud Run APIへ送信します。
SendGrid APIキーとAPI間の共有キーはFlutterやGitへ保存しません。

### 1. 共通Cloud Run API

`cloudrun/mail-api`をCloud Runへデプロイし、次の環境変数／Secretを設定します。

```env
SENDGRID_API_KEY=Secret Managerから設定
MAIL_API_KEY=十分に長いランダム値（Secret Managerから設定）
MAIL_FROM=noreply@jmcom.co.jp
MAIL_FROM_NAME=JMイベント事務局
MAIL_REPLY_TO=問い合わせ先メールアドレス
```

API契約は`POST /v1/mail/send`です。`Authorization: Bearer <MAIL_API_KEY>`と、
JSONの`to`、`subject`、`text`を受け取り、成功時は
`{"ok":true,"messageId":"..."}`を返します。Cloud Runは認証なし呼び出しを許可する場合でも、
必ず`MAIL_API_KEY`を設定してください。

```sh
gcloud run deploy jm-common-mail-api \
  --source cloudrun/mail-api \
  --region asia-northeast1 \
  --allow-unauthenticated \
  --set-env-vars 'MAIL_FROM=noreply@jmcom.co.jp,MAIL_FROM_NAME=JMイベント事務局' \
  --set-secrets 'SENDGRID_API_KEY=SENDGRID_API_KEY:latest,MAIL_API_KEY=MAIL_API_KEY:latest'
```

### 2. JM Quick Functions

```sh
firebase functions:secrets:set MAIL_API_KEY --project jm-quick
```

Functionsの環境設定として以下を設定します。

```env
APP_BASE_URL=https://実際に利用するホスト名
MAIL_API_URL=https://Cloud-RunサービスURL
```

`functions/.env.jm-quick` に設定後、次で配布します。

```sh
firebase deploy --only functions,firestore:rules --project jm-quick
```

`MAIL_API_KEY`はCloud RunとFunctionsで同じ値を設定します。SendGridで認証済みの
送信元ドメインを`MAIL_FROM`に使用してください。

## データ

- `events/demo-event`：イベント名、日時、会場、リコンファーム対象状態
- `participants/{participantId}`：公開ID、氏名、メール、登録人数、事前／当日区分、案内・参加確定・リコンファーム状態
- `checkIns/{participantId}`：受付状態、初回受付日時、実参加人数、最終更新日時
- `mailLogs/{id}`：Functionsだけが保存するメール送信記録
- `walkInRegistrations/{sha256(eventId + email)}`：同一イベント・同一メールの重複登録防止

QRとマイページURLには個人情報を含めず、参加者IDと十分に長いランダム公開IDだけを含めます。

## セキュリティと本番化

> **TEST ONLY:** 現在のRulesは、認証なしスタッフテストで管理画面の一覧を成立させるため、`demo-event` の参加者と受付の一覧readを許可しています。全データベース開放ではありませんが、本番利用は禁止です。

本番ではFirebase Authentication、管理・受付権限、App Check、参加者用の期限付きトークンまたはサーバーAPIを追加してください。認証なし管理画面と「公開ページから一覧を技術的にも取得不能にすること」は両立しないため、本番では必ず管理者認証を導入します。

リコンファームメールの自動送信はCloud Functions + Cloud Schedulerへ移し、再試行と送信監査を追加してください。CSV取込もサーバー側で検証してparticipantモデルへ登録します。
