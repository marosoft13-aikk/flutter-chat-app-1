// lib/screens/diagnostics_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart' as fb;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/diagnostics_store.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../scripts/migrate_conversations.dart'; // <-- import migration helper

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _runningMigration = false;
  bool _testingSignIn = false;

  Future<void> _showResultDialog(String title, String text) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _printAuthState() async {
    final authProv = Provider.of<AuthProvider?>(context, listen: false);
    final chatProv = Provider.of<ChatProvider?>(context, listen: false);
    final current = fb.FirebaseAuth.instance.currentUser;

    final sb = StringBuffer();
    sb.writeln('AuthProvider present: ${authProv != null}');
    sb.writeln('AuthProvider.loading: ${authProv?.loading}');
    sb.writeln('AuthProvider.user: ${authProv?.user?.uid ?? 'null'}');
    sb.writeln('FirebaseAuth.currentUser: ${current?.uid ?? 'null'}');
    sb.writeln('ChatProvider present: ${chatProv != null}');
    sb.writeln('ChatProvider.user: ${(chatProv?.user != null).toString()}');
    sb.writeln('');
    sb.writeln('DiagnosticsStore.logs (top 10):');
    for (final l in DiagnosticsStore.logs.take(10)) sb.writeln('- $l');
    sb.writeln('');
    sb.writeln('DiagnosticsStore.errors (top 10):');
    for (final e in DiagnosticsStore.errors.take(10)) sb.writeln('- $e');

    await _showResultDialog('Auth state', sb.toString());
  }

  Future<void> _migrateConversationsFromScript() async {
    if (_runningMigration) return;
    setState(() => _runningMigration = true);
    final sb = StringBuffer();
    try {
      await migrateConversations();
      sb.writeln('Migration finished — check console and Firestore.');
    } catch (e, st) {
      final msg = 'Migration error: $e\n$st';
      DiagnosticsStore.addError(msg);
      sb.writeln(msg);
    } finally {
      setState(() => _runningMigration = false);
    }
    await _showResultDialog('Migration result', sb.toString());
  }

  Future<void> _testSignInFlow() async {
    if (_testingSignIn) return;

    final emailCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Test sign-in (email)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailCtrl,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                controller: passCtrl,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('ok'),
              child: const Text('Sign in'),
            ),
          ],
        );
      },
    );

    if (result != 'ok') return;

    setState(() => _testingSignIn = true);
    try {
      final auth = Provider.of<AuthProvider>(context, listen: false);
      final res = await auth.signInWithEmail(
        emailCtrl.text.trim(),
        passCtrl.text.trim(),
      );
      if (res != null) {
        DiagnosticsStore.addError('Test sign-in failed: $res');
        await _showResultDialog('Sign-in result', 'Failed: $res');
      } else {
        await _showResultDialog(
          'Sign-in result',
          'Success — EntryPoint should navigate to chats.',
        );
      }
    } catch (e, st) {
      final msg = 'Test sign-in error: $e\n$st';
      DiagnosticsStore.addError(msg);
      await _showResultDialog('Sign-in error', msg);
    } finally {
      setState(() => _testingSignIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider?>(context);
    final chat = Provider.of<ChatProvider?>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionTitle('Firebase'),
            InfoRow(
              'initialized',
              DiagnosticsStore.firebaseInitialized ? 'yes' : 'no',
            ),
            const SizedBox(height: 8),
            SectionTitle('AuthProvider'),
            InfoRow('provider present', auth != null ? 'yes' : 'no'),
            InfoRow('loading', auth?.loading.toString() ?? 'n/a'),
            InfoRow('user', auth?.user?.uid ?? 'null'),
            const SizedBox(height: 8),
            SectionTitle('ChatProvider'),
            InfoRow('provider present', chat != null ? 'yes' : 'no'),
            InfoRow('chat.user', (chat?.user != null).toString()),
            const SizedBox(height: 12),

            // Diagnostic buttons
            ElevatedButton.icon(
              onPressed: _printAuthState,
              icon: const Icon(Icons.info_outline),
              label: const Text('Print auth state'),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _runningMigration
                  ? null
                  : _migrateConversationsFromScript,
              icon: const Icon(Icons.build),
              label: _runningMigration
                  ? const Text('Running migration...')
                  : const Text('Run migrateConversations'),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _testingSignIn ? null : _testSignInFlow,
              icon: const Icon(Icons.login),
              label: const Text('Test sign-in (email)'),
            ),
            const SizedBox(height: 16),

            ElevatedButton(
              onPressed: () => Navigator.of(context).pushNamed('/auth'),
              child: const Text('Open AuthScreen'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pushNamed('/chats'),
              child: const Text('Open ChatListScreen'),
            ),
            const SizedBox(height: 16),

            SectionTitle('Logs'),
            for (final l in DiagnosticsStore.logs.take(50))
              Text(l, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            SectionTitle('Errors (most recent)'),
            if (DiagnosticsStore.errors.isEmpty)
              const Text('No errors captured'),
            for (final e in DiagnosticsStore.errors.take(50))
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text(
                  e,
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const InfoRow(this.label, this.value, {super.key});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label: ', style: const TextStyle(fontWeight: FontWeight.bold)),
        Expanded(child: Text(value)),
      ],
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
      ),
    );
  }
}
