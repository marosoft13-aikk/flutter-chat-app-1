// lib/models/message.dart
import 'package:cloud_firestore/cloud_firestore.dart';

class Message {
  final String id;
  final String senderId;
  final String text;
  final String? imageUrl;
  final Timestamp createdAt;

  Message({
    required this.id,
    required this.senderId,
    required this.text,
    this.imageUrl,
    required this.createdAt,
  });

  factory Message.fromDoc(DocumentSnapshot doc) {
    final m = doc.data() as Map<String, dynamic>;
    return Message(
      id: doc.id,
      senderId: m['senderId'] ?? '',
      text: m['text'] ?? '',
      imageUrl: m['imageUrl'],
      createdAt: m['createdAt'] ?? Timestamp.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'senderId': senderId,
      'text': text,
      'imageUrl': imageUrl,
      'createdAt': createdAt,
    };
  }
}
