// lib/providers/chat_provider.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import '../providers/auth_provider.dart';
import '../utils/diagnostics_store.dart';

class ChatProvider extends ChangeNotifier {
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  AppUser? _user;

  // Defensive: notify only when uid actually changes to avoid redundant notifications
  void updateUser(AppUser? u) {
    final oldUid = _user?.uid;
    final newUid = u?.uid;
    _user = u;
    if (oldUid != newUid) {
      notifyListeners();
    }
  }

  AppUser? get user => _user;

  Stream<QuerySnapshot> messagesStream(String conversationId) {
    try {
      return _db
          .collection('conversations')
          .doc(conversationId)
          .collection('messages')
          .orderBy('createdAt', descending: true)
          .snapshots()
          .handleError((e) {
            debugPrint('messagesStream error for $conversationId: $e');
            DiagnosticsStore.addError(
              'messagesStream error for $conversationId: $e',
            );
          });
    } catch (e) {
      debugPrint('messagesStream setup failed: $e');
      DiagnosticsStore.addError('messagesStream setup failed: $e');
      return const Stream.empty();
    }
  }

  Future<void> sendText(String conversationId, String text) async {
    if (_user == null) throw Exception('Not authenticated');

    final collection = _db
        .collection('conversations')
        .doc(conversationId)
        .collection('messages');

    final msg = {
      'senderId': _user!.uid,
      'text': text,
      'imageUrl': null,
      'createdAt': FieldValue.serverTimestamp(),
    };

    try {
      await collection.add(msg);
      await _db.collection('conversations').doc(conversationId).set({
        'lastMessage': text,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      debugPrint('sendText: message sent to $conversationId');
    } catch (e) {
      debugPrint('sendText error: $e');
      DiagnosticsStore.addError('sendText error: $e');
      throw Exception('Failed to send message: $e');
    }
  }

  Future<void> sendImage(
    String conversationId,
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    if (_user == null) throw Exception('Not authenticated');
    if (!await file.exists()) throw Exception('File does not exist');

    final id = const Uuid().v4();
    final ref = _storage.ref().child('chat_images/$conversationId/$id.jpg');

    try {
      final uploadTask = ref.putFile(file);

      StreamSubscription<TaskSnapshot>? sub;
      if (onProgress != null) {
        sub = uploadTask.snapshotEvents.listen(
          (snapshot) {
            final total = snapshot.totalBytes;
            final transferred = snapshot.bytesTransferred;
            if (total > 0) {
              final p = transferred / total;
              try {
                onProgress(p.clamp(0.0, 1.0));
              } catch (_) {}
            }
          },
          onError: (e) {
            debugPrint('upload snapshot error: $e');
            DiagnosticsStore.addError('upload snapshot error: $e');
          },
        );
      }

      final snapshot = await uploadTask;
      await sub?.cancel();

      final url = await snapshot.ref.getDownloadURL();

      final collection = _db
          .collection('conversations')
          .doc(conversationId)
          .collection('messages');

      final msg = {
        'senderId': _user!.uid,
        'text': '',
        'imageUrl': url,
        'createdAt': FieldValue.serverTimestamp(),
      };

      await collection.add(msg);
      await _db.collection('conversations').doc(conversationId).set({
        'lastMessage': '[image]',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint(
        'sendImage: uploaded and message created for $conversationId (url: $url)',
      );
    } catch (e) {
      debugPrint('sendImage error: $e');
      DiagnosticsStore.addError('sendImage error: $e');
      throw Exception('Failed to upload image: $e');
    }
  }

  String _dmIdFor(String a, String b) {
    final list = [a, b]..sort();
    return 'dm_${list[0]}_${list[1]}';
  }

  Future<String> getOrCreateConversationWith(
    String otherUserId, {
    String? title,
  }) async {
    if (_user == null) throw Exception('Not authenticated');

    final convId = _dmIdFor(_user!.uid, otherUserId);
    final convRef = _db.collection('conversations').doc(convId);

    try {
      final snap = await convRef.get();
      if (snap.exists) {
        debugPrint('getOrCreateConversationWith: found existing conv $convId');
        return convId;
      }

      await convRef.set({
        'type': 'dm',
        'members': [_user!.uid, otherUserId],
        'title': title ?? '',
        'lastMessage': '',
        'updatedAt': FieldValue.serverTimestamp(),
      });

      debugPrint('getOrCreateConversationWith: created conv $convId');
      return convId;
    } catch (e) {
      debugPrint('getOrCreateConversationWith error: $e');
      DiagnosticsStore.addError('getOrCreateConversationWith error: $e');
      throw Exception('Failed to create/obtain conversation: $e');
    }
  }

  Future<String> createConversationWith(String otherUserId, {String? title}) {
    return getOrCreateConversationWith(otherUserId, title: title);
  }

  // Robust conversations stream:
  // - try primary query with orderBy(updatedAt)
  // - if that stream emits an index-related error, switch to fallback stream without orderBy
  Stream<QuerySnapshot> conversationsStream() {
    if (_user == null) return const Stream.empty();

    final controller = StreamController<QuerySnapshot>();
    StreamSubscription<QuerySnapshot>? sub;

    void startFallback() {
      try {
        final fallback = _db
            .collection('conversations')
            .where('members', arrayContains: _user!.uid)
            .snapshots();
        sub = fallback.listen(
          (ev) => controller.add(ev),
          onError: (e, st) {
            debugPrint('conversationsStream fallback error: $e');
            DiagnosticsStore.addError('conversationsStream fallback error: $e');
            controller.addError(e, st);
          },
        );
      } catch (e, st) {
        debugPrint('conversationsStream fallback setup failed: $e');
        DiagnosticsStore.addError(
          'conversationsStream fallback setup failed: $e',
        );
        controller.addError(e, st);
      }
    }

    void startPrimary() {
      try {
        final primary = _db
            .collection('conversations')
            .where('members', arrayContains: _user!.uid)
            .orderBy('updatedAt', descending: true)
            .snapshots();

        sub = primary.listen(
          (ev) => controller.add(ev),
          onError: (e, st) async {
            debugPrint('conversationsStream primary error: $e');
            DiagnosticsStore.addError('conversationsStream primary error: $e');

            // detect index-related errors loosely by message
            final msg = e.toString().toLowerCase();
            if (msg.contains('index') ||
                msg.contains('failed_precondition') ||
                msg.contains('requires an index')) {
              // switch to fallback without orderBy
              await sub?.cancel();
              startFallback();
            } else {
              // forward other errors
              controller.addError(e, st);
            }
          },
        );
      } catch (e, st) {
        // if constructing the primary throws synchronously, fallback
        debugPrint('conversationsStream setup error: $e');
        DiagnosticsStore.addError('conversationsStream setup error: $e');
        startFallback();
      }
    }

    controller.onListen = startPrimary;
    controller.onCancel = () async {
      await sub?.cancel();
      await controller.close();
    };

    return controller.stream;
  }
}
