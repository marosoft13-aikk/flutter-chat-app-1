// scripts/migrate_conversations.dart
import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> migrateConversations() async {
  final db = FirebaseFirestore.instance;
  final col = db.collection('conversations');
  final snapshots = await col.get();

  for (final doc in snapshots.docs) {
    final data = doc.data();
    final updates = <String, dynamic>{};

    // fix members if stored as a string
    final members = data['members'];
    if (members != null && members is String) {
      updates['members'] = [members];
    }

    // normalize lastMessage field (remove weird wrapping quotes)
    final lmCandidates = ['lastmessage', 'lastMessage'];
    for (final key in lmCandidates) {
      final lm = data[key];
      if (lm is String) {
        var newLm = lm;
        if (newLm.startsWith('"') && newLm.endsWith('"')) {
          newLm = newLm.substring(1, newLm.length - 1);
        }
        updates['lastMessage'] = newLm;
        break;
      }
    }

    // fix timestamp-like fields that were stored as string "null"
    final timeFields = ['lastmessagetime', 'lastMessageTime', 'updatedAt'];
    for (final f in timeFields) {
      final v = data[f];
      if (v is String && v.toLowerCase() == 'null') {
        updates['updatedAt'] = FieldValue.serverTimestamp();
        break;
      }
    }

    if (updates.isNotEmpty) {
      await col.doc(doc.id).set(updates, SetOptions(merge: true));
      print('Migrated ${doc.id} -> $updates');
    }
  }
}
