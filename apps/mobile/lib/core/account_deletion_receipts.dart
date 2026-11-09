part of 'push.dart';

enum AccountDeletionStatus { deleted, pending, unknown }

class AccountDeletionUnconfirmed implements Exception {
  const AccountDeletionUnconfirmed(this.status);
  final AccountDeletionStatus status;
}

const _deletionReceiptKey = 'futbeat.account.deletionReceipt';
final _deletionUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

String _newDeletionId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

extension _AccountDeletionReceipts on PushService {
  Future<String?> _receiptFor(String uid) async {
    final raw = await storage.read(key: _deletionReceiptKey);
    if (raw == null) return null;
    final receipt = jsonDecode(raw);
    if (receipt is! Map ||
        receipt['uid'] != uid ||
        receipt['phase'] == 'conflict' ||
        receipt['deletionId'] is! String ||
        !_deletionUuid.hasMatch(receipt['deletionId'] as String)) {
      throw const AccountDeletionUnconfirmed(AccountDeletionStatus.unknown);
    }
    return receipt['deletionId'] as String;
  }

  Future<AccountDeletionStatus> _receiptStatus(String id) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '${config.supabaseUrl}/rest/v1/rpc/futbeat_account_deletion_status',
        data: {'p_deletion_id': id},
        options: Options(
          headers: {'apikey': config.publicKey},
          contentType: Headers.jsonContentType,
        ),
      );
      if (response.statusCode != 200) return AccountDeletionStatus.unknown;
      return switch (response.data?['status']) {
        'deleted' => AccountDeletionStatus.deleted,
        'pending' => AccountDeletionStatus.pending,
        _ => AccountDeletionStatus.unknown,
      };
    } on DioException {
      return AccountDeletionStatus.unknown;
    }
  }

  Future<void> _requestDeletionWithReceipt(String uid, int generation) async {
    void checkAccount() {
      if (_stale(generation) || userId != uid || !registered) {
        throw StateError('Account changed during deletion');
      }
    }

    var id = await _receiptFor(uid);
    if (id != null &&
        await _receiptStatus(id) == AccountDeletionStatus.deleted) {
      checkAccount();
      return;
    }
    checkAccount();
    final expiresAt = num.tryParse(session?['expires_at'].toString() ?? '');
    if (expiresAt != null &&
        expiresAt <= clock().millisecondsSinceEpoch / 1000 + 60) {
      try {
        await refreshSession();
      } catch (_) {
        checkAccount();
        if (id != null &&
            await _receiptStatus(id) == AccountDeletionStatus.deleted) {
          checkAccount();
          return;
        }
        throw const AccountDeletionUnconfirmed(AccountDeletionStatus.unknown);
      }
    }
    checkAccount();
    if (id == null) {
      id = _newDeletionId();
      final receipt = jsonEncode({
        'uid': uid,
        'deletionId': id,
        'startedAt': clock().toUtc().toIso8601String(),
        'phase': 'requested',
      });
      await storage.write(key: _deletionReceiptKey, value: receipt);
      if (await _receiptFor(uid) != id) {
        throw const AccountDeletionUnconfirmed(AccountDeletionStatus.unknown);
      }
    }
    checkAccount();
    final response = await dio
        .post<Map<String, dynamic>>(
          '${config.supabaseUrl}/functions/v1/futbeat-delete-account',
          options: Options(
            headers: {...authHeaders.headers!, 'X-FutBeat-Deletion-Id': id},
            sendTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 20),
            validateStatus: (code) => code != null,
            followRedirects: false,
          ),
        )
        .onError<DioException>((_, _) async {
          return Response(requestOptions: RequestOptions());
        });
    checkAccount();
    if (response.statusCode == 200 &&
        response.data?['deleted'] == true &&
        response.data?['deletionId'] == id) {
      return;
    }
    if (response.statusCode == 409) {
      // This receipt may belong to a different user. Its status cannot prove
      // deletion of the current account.
      await storage.write(
        key: _deletionReceiptKey,
        value: jsonEncode({'uid': uid, 'deletionId': id, 'phase': 'conflict'}),
      );
      throw const AccountDeletionUnconfirmed(AccountDeletionStatus.unknown);
    }
    if (response.statusCode == 400 || response.statusCode == 403) {
      throw const AccountDeletionUnconfirmed(AccountDeletionStatus.unknown);
    }
    final status = await _receiptStatus(id);
    checkAccount();
    if (status != AccountDeletionStatus.deleted) {
      throw AccountDeletionUnconfirmed(status);
    }
  }

  Future<void> _forgetDeletionReceipt(String uid) async {
    if (await _receiptFor(uid) != null) {
      await storage.delete(key: _deletionReceiptKey);
    }
  }
}
