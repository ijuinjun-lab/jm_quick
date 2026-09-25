import 'package:firebase_auth/firebase_auth.dart';

/// ログインに失敗したときの、画面へそのまま表示できる(内部情報を含まない)メッセージ。
class AuthFailure implements Exception {
  const AuthFailure(this.message, {this.code});
  final String? code;
  final String message;
  @override
  String toString() => message;
}

/// Firebase Authenticationへの薄い窓口。画面はこの抽象にだけ依存する(テストでは差し替える)。
/// 招待画面は現在のメールを招待先と照合する。パスワードはAuth SDK以外へ渡さない。
abstract class AuthClient {
  /// ログイン状態の変化(true=ログイン済み)。購読開始時に現在の状態も流す。
  Stream<bool> signedInChanges();

  String? get currentEmail;
  Future<void> register(String email, String password);
  Future<void> signIn(String email, String password);
  Future<void> signOut();

  /// サーバーへ送るIDトークン。ログインしていなければnull。
  Future<String?> idToken({bool forceRefresh = false});
}

class FirebaseAuthClient implements AuthClient {
  FirebaseAuthClient({FirebaseAuth? auth}) : _auth = auth;
  FirebaseAuth? _auth;

  /// Firebase初期化後の最初の利用時に取得する。
  FirebaseAuth get auth => _auth ??= FirebaseAuth.instance;

  @override
  Stream<bool> signedInChanges() =>
      auth.authStateChanges().map((user) => user != null);

  @override
  Future<void> signIn(String email, String password) async {
    try {
      await auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (error) {
      throw AuthFailure(messageForCode(error.code));
    } catch (_) {
      throw const AuthFailure('ログインできませんでした。通信状態を確認して、もう一度お試しください。');
    }
  }

  @override
  String? get currentEmail => auth.currentUser?.email;

  @override
  Future<void> register(String email, String password) async {
    try {
      // Firebase側の既存password policyに従う。Functionsへpasswordは送らない。
      await auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
    } on FirebaseAuthException catch (error) {
      throw AuthFailure(switch (error.code) {
        'email-already-in-use' => '登録済みです。設定したパスワードでログインして招待を受けてください。',
        'weak-password' || 'password-does-not-meet-requirements' =>
          'パスワードが必要な条件を満たしていません。より長く、英大文字・小文字・数字・記号を含むパスワードを設定してください。',
        _ => messageForCode(error.code),
      }, code: error.code);
    } catch (_) {
      throw const AuthFailure('登録結果を確認できません。登録済みの場合はログインして再開してください。');
    }
  }

  @override
  Future<void> signOut() => auth.signOut();

  @override
  Future<String?> idToken({bool forceRefresh = false}) async =>
      auth.currentUser?.getIdToken(forceRefresh);

  /// エラーコードから表示文を決める。アカウントの有無を推測させないため、
  /// メール未登録とパスワード誤りは同じ文言にする。
  static String messageForCode(String code) => switch (code) {
    'invalid-email' ||
    'user-not-found' ||
    'wrong-password' ||
    'invalid-credential' ||
    'invalid-login-credentials' => 'メールアドレスまたはパスワードが正しくありません。',
    'user-disabled' => 'このアカウントは無効になっています。',
    'too-many-requests' => '試行回数が多すぎます。しばらくしてからもう一度お試しください。',
    'network-request-failed' => '通信に失敗しました。通信状態を確認してください。',
    _ => 'ログインできませんでした。',
  };
}
