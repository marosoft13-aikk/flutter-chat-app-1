// lib/screens/chat_list_screen.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import 'chat_room_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  // Simple relative time formatter for Firestore Timestamps
  String _formatRelative(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate();
    final diff = DateTime.now().difference(d);

    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  // Safely read display name and photoUrl from auth.user without assuming concrete AppUser API.
  Map<String, String?> _userProfile(AuthProvider auth) {
    final dyn = auth.user as dynamic?;
    if (dyn == null) return {'name': null, 'photo': null, 'uid': null};
    try {
      final name = (dyn.displayName ?? dyn.name ?? dyn.email) as String?;
      final photo = (dyn.photoUrl ?? dyn.avatarUrl ?? dyn.photo) as String?;
      final uid = (dyn.uid ?? dyn.id) as String?;
      return {'name': name, 'photo': photo, 'uid': uid};
    } catch (_) {
      return {'name': null, 'photo': null, 'uid': null};
    }
  }

  Future<void> _showCreateChatDialog(
    BuildContext context,
    AuthProvider auth,
    ChatProvider chat,
  ) async {
    final controller = TextEditingController();
    String? errorText;

    final convId = await showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setState) {
            bool loading = false;

            Future<void> onCreate() async {
              final input = controller.text.trim();

              if (!dialogCtx.mounted) return;

              setState(() {
                errorText = null;
              });

              if (input.isEmpty) {
                if (!dialogCtx.mounted) return;
                setState(() {
                  errorText = 'Please enter a user id or email';
                });
                return;
              }

              final currentUid = auth.user?.uid;
              try {
                if (!dialogCtx.mounted) return;
                setState(() {
                  loading = true;
                  errorText = null;
                });

                String otherUid = input;

                if (input.contains('@')) {
                  final snap = await FirebaseFirestore.instance
                      .collection('users')
                      .where('email', isEqualTo: input)
                      .limit(1)
                      .get();
                  if (snap.docs.isEmpty) {
                    if (!dialogCtx.mounted) return;
                    setState(() {
                      errorText = 'No user found with this email';
                      loading = false;
                    });
                    return;
                  }
                  otherUid = snap.docs.first.id;
                }

                if (currentUid != null && otherUid == currentUid) {
                  if (!dialogCtx.mounted) return;
                  setState(() {
                    errorText = 'Cannot start a chat with yourself';
                    loading = false;
                  });
                  return;
                }

                final convId = await chat.getOrCreateConversationWith(otherUid);

                if (dialogCtx.mounted) {
                  Navigator.of(dialogCtx).pop(convId);
                }
              } catch (e) {
                if (!dialogCtx.mounted) return;
                setState(() {
                  errorText = e.toString();
                  loading = false;
                });
              }
            }

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              title: const Text('Start a new chat'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: 'User ID or email',
                      hintStyle: const TextStyle(color: Colors.black38),
                      errorText: errorText,
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autofocus: true,
                    onSubmitted: (_) => onCreate(),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    if (dialogCtx.mounted) Navigator.of(dialogCtx).pop(null);
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: loading ? null : onCreate,
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: loading
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    if (convId != null && convId.isNotEmpty && context.mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatRoomScreen(conversationId: convId),
            ),
          );
        }
      });
    }
  }

  Widget _buildEmptyState(BuildContext context, VoidCallback onCreate) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.amber.shade700, Colors.deepOrange.shade400],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(16),
              child: Icon(Icons.forum, size: 56, color: Colors.white),
            ),
            const SizedBox(height: 18),
            const Text(
              'No conversations yet',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Start a private, secure conversation. Invite colleagues or friends and enjoy a premium chat experience.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('Start Chat'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                backgroundColor: Colors.amber.shade700,
                foregroundColor: Colors.white,
                elevation: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationTile(BuildContext context, QueryDocumentSnapshot d) {
    final data = d.data() as Map<String, dynamic>? ?? {};
    final title = (data['title'] != null && data['title'].toString().isNotEmpty)
        ? data['title'].toString()
        : 'Conversation';
    final last = (data['lastMessage'] ?? data['lastmessage'] ?? '').toString();
    final ts = data['lastUpdated'] is Timestamp
        ? data['lastUpdated'] as Timestamp
        : (data['updatedAt'] is Timestamp
              ? data['updatedAt'] as Timestamp
              : null);
    final unreadCount = (data['unreadCount'] is int)
        ? data['unreadCount'] as int
        : 0;
    final photoUrl =
        (data['photoUrl'] is String && (data['photoUrl'] as String).isNotEmpty)
        ? data['photoUrl'] as String
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
      child: Material(
        color: Colors.white,
        elevation: 6,
        borderRadius: BorderRadius.circular(14),
        shadowColor: Colors.black.withOpacity(0.12),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            if (context.mounted) {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatRoomScreen(conversationId: d.id),
                ),
              );
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                _AvatarWithRing(
                  radius: 30,
                  photoUrl: photoUrl,
                  label: title.isNotEmpty
                      ? title.substring(0, 1).toUpperCase()
                      : '?',
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _formatRelative(ts),
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (unreadCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.amber.shade700,
                              Colors.deepOrange.shade400,
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.12),
                              blurRadius: 6,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Text(
                          unreadCount > 99 ? '99+' : unreadCount.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    else
                      Icon(Icons.chevron_right, color: Colors.grey.shade400),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final chatUser = context.select<ChatProvider, dynamic>((p) => p.user);
    final chat = Provider.of<ChatProvider>(context, listen: false);

    if (chatUser == null) {
      return Scaffold(
        backgroundColor: Colors.grey.shade100,
        appBar: AppBar(title: const Text('Chats'), centerTitle: true),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final profile = _userProfile(auth);
    final userInitial = (profile['name'] != null && profile['name']!.isNotEmpty)
        ? profile['name']![0].toUpperCase()
        : '?';
    final photo = profile['photo'];

    final media = MediaQuery.of(context);
    final topPad = media.padding.top;

    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: PreferredSize(
        // Height: status bar (topPad) + appbar content (72)
        preferredSize: Size.fromHeight(topPad + 72),
        child: Container(
          padding: EdgeInsets.only(
            top: topPad,
            left: 12,
            right: 12,
            bottom: 12,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Colors.deepPurple.shade800, Colors.deepPurple.shade600],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(18),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    // profile action
                  },
                  child: _AvatarWithRing(
                    radius: 28,
                    photoUrl: photo,
                    label: userInitial,
                    ringColors: [Colors.amber.shade600, Colors.orange.shade400],
                    elevated: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Messages',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Secure · Private · Premium',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.85),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () {
                    showSearch(
                      context: context,
                      delegate: _DummySearchDelegate(),
                    );
                  },
                  icon: const Icon(Icons.search, color: Colors.white),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () async {
                    try {
                      await auth.signOut();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Sign out failed: $e')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.logout, color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: chat.conversationsStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            final err = snapshot.error.toString().toLowerCase();
            if (err.contains('index') ||
                err.contains('requires an index') ||
                err.contains('failed_precondition')) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.error_outline, size: 48, color: Colors.orange),
                      SizedBox(height: 12),
                      Text(
                        'This query requires a Firestore index.\nOpen Firebase Console and create the suggested index.',
                        textAlign: TextAlign.center,
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Tip: run the app from the terminal and follow the link that appears in the console when the index is required.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              );
            }
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];
          if (docs.isEmpty) {
            return _buildEmptyState(
              context,
              () => _showCreateChatDialog(context, auth, chat),
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              await Future<void>.delayed(const Duration(milliseconds: 400));
            },
            color: Colors.amber.shade700,
            child: ListView.separated(
              padding: const EdgeInsets.only(top: 12, bottom: 18),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, i) =>
                  _buildConversationTile(context, docs[i]),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateChatDialog(context, auth, chat),
        tooltip: 'Start new chat',
        backgroundColor: Colors.amber.shade700,
        child: const Icon(Icons.add_comment, color: Colors.white),
        elevation: 8,
      ),
    );
  }
}

class _AvatarWithRing extends StatelessWidget {
  final double radius;
  final String? photoUrl;
  final String label;
  final List<Color>? ringColors;
  final bool elevated;

  const _AvatarWithRing({
    super.key,
    required this.radius,
    required this.label,
    this.photoUrl,
    this.ringColors,
    this.elevated = false,
  });

  @override
  Widget build(BuildContext context) {
    final ring =
        ringColors ??
        [Colors.white.withOpacity(0.9), Colors.white.withOpacity(0.6)];

    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: ring,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.all(3),
      child: CircleAvatar(
        radius: radius - 3,
        backgroundColor: Colors.grey.shade200,
        backgroundImage: photoUrl != null ? NetworkImage(photoUrl!) : null,
        child: photoUrl == null
            ? Text(
                label,
                style: TextStyle(
                  color: Colors.grey.shade800,
                  fontWeight: FontWeight.w700,
                  fontSize: (radius / 1.8).clamp(12, 20),
                ),
              )
            : null,
      ),
    );
  }
}

// A very small SearchDelegate placeholder - replace with a real implementation if desired.
class _DummySearchDelegate extends SearchDelegate<String> {
  @override
  String get searchFieldLabel => 'Search conversations';

  @override
  List<Widget>? buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, ''),
  );

  @override
  Widget buildResults(BuildContext context) =>
      Center(child: Text('Search not implemented - query: "$query"'));

  @override
  Widget buildSuggestions(BuildContext context) => const SizedBox.shrink();
}
