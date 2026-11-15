part of 'push.dart';

enum AccountDeletionStatus { deleted, pending, unknown }

class AccountDeletionUnconfirmed implements Exception {
  const AccountDeletionUnconfirmed(this.status);
  final AccountDeletionStatus status;
}

const _deletionReceiptKey = 'futbeat.account.deletionReceipt';
const _r05PhysicalDiagnostics =
    bool.fromEnvironment('FUTBEAT_R05_TEST_PACKAGE') &&
    bool.fromEnvironment('FUTBEAT_R05_PHYSICAL_DIAGNOSTICS');
const _r05CaseA = String.fromEnvironment('FUTBEAT_R05_CASE_A_HASH');
const _r05CaseB = String.fromEnvironment('FUTBEAT_R05_CASE_B_HASH');
const _r05Case2 = String.fromEnvironment('FUTBEAT_R05_CASE_2_HASH');
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
      if (_r05PhysicalDiagnostics) {
        final status = response.data?['status'];
        debugPrint(
          'FB_R05 receipt HTTP 200 '
          '${const {'deleted', 'pending', 'unknown'}.contains(status) ? status : 'unexpected'}',
        );
      }
      return switch (response.data?['status']) {
        'deleted' => AccountDeletionStatus.deleted,
        'pending' => AccountDeletionStatus.pending,
        _ => AccountDeletionStatus.unknown,
      };
    } on DioException catch (error) {
      if (_r05PhysicalDiagnostics &&
          error.type == DioExceptionType.connectionError) {
        debugPrint('FB_R05 receipt transport unavailable');
      }
      return AccountDeletionStatus.unknown;
    }
  }

  Future<void> _requestDeletionWithReceipt(String uid, int generation) async {
    final accountHash = _r05PhysicalDiagnostics
        ? sha256.convert(utf8.encode(uid)).toString()
        : null;
    if (_r05PhysicalDiagnostics &&
        (accountHash != _r05CaseA &&
            accountHash != _r05CaseB &&
            accountHash != _r05Case2)) {
      throw StateError('R05 Test account is outside the authorized pair');
    }
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
    if (_r05PhysicalDiagnostics && accountHash == _r05Case2) {
      debugPrint('FB_R05 C2 POST armed; receipt persisted and reread');
    }
    final deletionOptions = Options(
      headers: {...authHeaders.headers!, 'X-FutBeat-Deletion-Id': id},
      sendTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      validateStatus: (code) => code != null,
      followRedirects: false,
    );
    final response = await dio
        .post<Map<String, dynamic>>(
          '${config.supabaseUrl}/functions/v1/futbeat-delete-account',
          options: deletionOptions,
        )
        .onError<DioException>((_, _) async {
          return Response(requestOptions: RequestOptions());
        });
    checkAccount();
    if (response.statusCode == 200 &&
        response.data?['deleted'] == true &&
        response.data?['deletionId'] == id) {
      if (_r05PhysicalDiagnostics) {
        debugPrint('FB_R05 POST HTTP 200 receipt matched');
        if (accountHash == _r05Case2) {
          debugPrint('FB_R05 C2 response held until process exit');
          await Completer<void>().future;
        }
        if (accountHash == _r05CaseB) {
          // Keep the durable receipt and allow the operator to end only this
          // test process before the client consumes the successful response.
          debugPrint('FB_R05 case B response held for process interruption');
          await Future<void>.delayed(const Duration(seconds: 25));
          throw const AccountDeletionUnconfirmed(AccountDeletionStatus.unknown);
        }
        final replay = await dio
            .post<Map<String, dynamic>>(
              '${config.supabaseUrl}/functions/v1/futbeat-delete-account',
              options: deletionOptions,
            )
            .onError<DioException>(
              (_, _) => Response(requestOptions: RequestOptions()),
            );
        debugPrint(
          'FB_R05 case A replay HTTP ${replay.statusCode ?? 0} '
          'alreadyDeleted=${replay.data?['alreadyDeleted'] == true} '
          'receiptMatched=${replay.data?['deletionId'] == id}',
        );
        await _receiptStatus(id);
        checkAccount();
      }
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
