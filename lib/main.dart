// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';

import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'screens/auth_screen.dart';
import 'screens/chat_list_screen.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    debugPrint('Firebase initialized');
  } catch (e, st) {
    debugPrint('Firebase.initializeApp failed: $e\n$st');
    // continue running; AuthProvider will surface auth-specific errors
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // AuthProvider
        ChangeNotifierProvider<AuthProvider>(
          create: (_) {
            final p = AuthProvider();
            p.init(); // fire-and-forget async init
            return p;
          },
        ),

        // ChatProvider proxy that reuses previous instance and gets user updates
        ChangeNotifierProxyProvider<AuthProvider, ChatProvider>(
          create: (_) => ChatProvider(),
          update: (_, auth, previous) {
            final provider = previous ?? ChatProvider();
            provider.updateUser(auth.user);
            return provider;
          },
        ),
      ],
      child: MaterialApp(
        title: 'Chat App',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(primarySwatch: Colors.deepPurple),
        // keep simple EntryPoint (restores reliable auth flow)
        home: const EntryPoint(),
        routes: {
          '/auth': (_) => const AuthScreen(),
          '/chats': (_) => const ChatListScreen(),
        },
      ),
    );
  }
}

class EntryPoint extends StatelessWidget {
  const EntryPoint({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);

    if (auth.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (auth.user == null) return const AuthScreen();

    return const ChatListScreen();
  }
}
