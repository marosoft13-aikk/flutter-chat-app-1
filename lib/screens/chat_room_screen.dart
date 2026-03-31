// ChatRoomScreen — uses signed Cloudinary uploads via a signing server
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:intl/intl.dart';
import 'package:record/record.dart' as rec;
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import '../models/message.dart';
import '../providers/chat_provider.dart';

class ChatRoomScreen extends StatefulWidget {
  // فقط السطر ده اضبطه في أعلى الملف:
  static const String SIGNING_SERVER_URL =
      'https://winford-uncohesive-rylie.ngrok-free.dev';

  final String conversationId;
  final String? title;
  const ChatRoomScreen({super.key, required this.conversationId, this.title});

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen>
    with TickerProviderStateMixin {
  // ====== CONFIG ======
  // cloud name is returned by the sign server, but you can set default here if needed
  static const String FALLBACK_CLOUDINARY_CLOUD_NAME = 'YOUR_CLOUD_NAME';
  // ====================

  final rec.AudioRecorder _recorder = rec.AudioRecorder();

  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  bool _isRecording = false;
  final _picker = ImagePicker();

  final AudioPlayer _player = AudioPlayer();
  String? _recordPath;
  bool _playing = false;
  String? _playingUrl;
  Duration _playProgress = Duration.zero;
  Duration _playDuration = Duration.zero;

  Timer? _recTimer;
  Stopwatch? _recordStopwatch;

  final List<String> _stickers = [
    'https://i.imgur.com/BoN9kdC.png',
    'https://i.imgur.com/2yaf2wb.png',
    'https://i.imgur.com/OvMZBs9.png',
    'https://i.imgur.com/HYcn9xO.png',
  ];

  @override
  void initState() {
    super.initState();
    // طباعة تأكيد قيمة SIGNING_SERVER_URL عند الإقلاع لتتأكد أن التطبيق يستخدم الـ ngrok
    debugPrint('Using signing server: ${ChatRoomScreen.SIGNING_SERVER_URL}');

    _player.onPlayerComplete.listen((_) {
      setState(() {
        _playing = false;
        _playingUrl = null;
        _playProgress = Duration.zero;
        _playDuration = Duration.zero;
      });
    });
    _player.onPositionChanged.listen((pos) {
      setState(() {
        _playProgress = pos;
      });
    });
    _player.onDurationChanged.listen((d) {
      setState(() {
        _playDuration = d;
      });
    });

    _controller.addListener(() {
      setState(() {}); // to toggle send/mic icon
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _player.dispose();
    _recTimer?.cancel();
    _recordStopwatch?.stop();
    super.dispose();
  }

  String _timeFromTimestamp(Timestamp? ts) {
    if (ts == null) return '';
    final dt = ts.toDate();
    return DateFormat.Hm().format(dt);
  }

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final chat = Provider.of<ChatProvider>(context, listen: false);
      await chat.sendText(widget.conversationId, text);
      _controller.clear();
      _scrollToBottomDelayed();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _contentTypeFromPath(String path) {
    final ext = path.toLowerCase();
    if (ext.endsWith('.png')) return 'image/png';
    if (ext.endsWith('.jpg') || ext.endsWith('.jpeg')) return 'image/jpeg';
    if (ext.endsWith('.gif')) return 'image/gif';
    if (ext.endsWith('.webp')) return 'image/webp';
    if (ext.endsWith('.m4a')) return 'audio/mp4';
    if (ext.endsWith('.mp3')) return 'audio/mpeg';
    if (ext.endsWith('.wav')) return 'audio/wav';
    if (ext.endsWith('.mp4')) return 'video/mp4';
    if (ext.endsWith('.mov')) return 'video/quicktime';
    if (ext.endsWith('.webm')) return 'video/webm';
    return 'application/octet-stream';
  }

  // 1) Request signature from signing server
  Future<Map<String, dynamic>> _fetchSignature({String? folder}) async {
    // استخدم الثابت الموحد في ChatRoomScreen
    final url = Uri.parse(
      '${ChatRoomScreen.SIGNING_SERVER_URL}/cloudinary/sign',
    );
    final body = json.encode({
      'conversationId': widget.conversationId,
      if (folder != null) 'folder': folder,
    });
    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );
    if (resp.statusCode != 200) {
      debugPrint('Sign server failed: ${resp.statusCode} ${resp.body}');
      throw Exception('Sign fetch failed: ${resp.statusCode}');
    }
    final Map<String, dynamic> j = json.decode(resp.body);
    return j;
  }

  // 2) Upload file to Cloudinary using signed params returned by signing server
  Future<String> _uploadFileAndGetUrl(
    File file,
    String storagePath, {
    void Function(double progress)? onProgress,
  }) async {
    // Request signature first (server returns signature, timestamp, api_key, cloud_name, folder)
    final signJson = await _fetchSignature(
      folder: 'chat_uploads/${widget.conversationId}',
    );
    final signature = signJson['signature']?.toString();
    final timestamp = signJson['timestamp']?.toString();
    final apiKey = signJson['api_key']?.toString();
    final cloudName =
        signJson['cloud_name']?.toString() ?? FALLBACK_CLOUDINARY_CLOUD_NAME;
    final folder =
        signJson['folder']?.toString() ??
        'chat_uploads/${widget.conversationId}';

    if (signature == null || timestamp == null || apiKey == null) {
      debugPrint('Invalid sign response: $signJson');
      throw Exception('Invalid sign response from server');
    }

    final uri = Uri.parse(
      'https://api.cloudinary.com/v1_1/$cloudName/auto/upload',
    );
    final request = http.MultipartRequest('POST', uri);

    // Signed fields (must match server-side signature generation)
    request.fields['api_key'] = apiKey;
    request.fields['timestamp'] = timestamp;
    request.fields['signature'] = signature;
    request.fields['folder'] = folder;

    // Attach file
    final multipartFile = await http.MultipartFile.fromPath('file', file.path);
    request.files.add(multipartFile);

    debugPrint('Uploading to Cloudinary (signed) -> $uri, file=${file.path}');

    final streamedResponse = await request.send();

    final respStr = await streamedResponse.stream.bytesToString();
    debugPrint('Cloudinary STATUS: ${streamedResponse.statusCode}');
    debugPrint('Cloudinary BODY: $respStr');

    if (streamedResponse.statusCode < 200 ||
        streamedResponse.statusCode >= 300) {
      throw Exception(
        'Cloudinary upload failed: ${streamedResponse.statusCode} - $respStr',
      );
    }

    final Map<String, dynamic> jsonResp = json.decode(respStr);
    final url = (jsonResp['secure_url'] ?? jsonResp['url'] ?? '').toString();
    if (url.isEmpty) {
      debugPrint('Missing secure_url in Cloudinary response: $jsonResp');
      throw Exception('Cloudinary response missing secure_url');
    }

    try {
      if (onProgress != null) onProgress(1.0);
    } catch (_) {}

    return url;
  }

  Future<void> _pickAndSendImage() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked == null) return;
    final file = File(picked.path);
    try {
      final pathInStorage =
          'chat_images/${widget.conversationId}/${DateTime.now().millisecondsSinceEpoch}${_getExtension(file.path)}';

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Uploading image...')));
      }

      final url = await _uploadFileAndGetUrl(
        file,
        pathInStorage,
        onProgress: (p) {
          // You can update UI with progress if needed
        },
      );

      debugPrint('Image uploaded. storagePath=$pathInStorage url=$url');

      // write message
      final db = FirebaseFirestore.instance;
      final messagesRef = db
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages');
      await messagesRef.add({
        'senderId':
            Provider.of<ChatProvider>(context, listen: false).user?.uid ?? '',
        'text': '',
        'imageUrl': url,
        'sticker': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await db.collection('conversations').doc(widget.conversationId).set({
        'lastMessage': '[image]',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _scrollToBottomDelayed();

      if (context.mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
    } catch (e) {
      debugPrint('Image upload error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Image upload failed: $e')));
      }
    }
  }

  Future<void> _pickAndSendVideo() async {
    final picked = await _picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 5),
    );
    if (picked == null) return;
    final file = File(picked.path);
    try {
      final pathInStorage =
          'chat_videos/${widget.conversationId}/${DateTime.now().millisecondsSinceEpoch}${_getExtension(file.path)}';

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Uploading video...')));
      }

      final url = await _uploadFileAndGetUrl(
        file,
        pathInStorage,
        onProgress: (p) {
          // progress UI hook
        },
      );

      debugPrint('Video uploaded. storagePath=$pathInStorage url=$url');

      final db = FirebaseFirestore.instance;
      final messagesRef = db
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages');
      await messagesRef.add({
        'senderId':
            Provider.of<ChatProvider>(context, listen: false).user?.uid ?? '',
        'text': '',
        'videoUrl': url,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await db.collection('conversations').doc(widget.conversationId).set({
        'lastMessage': '[video]',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _scrollToBottomDelayed();

      if (context.mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    } catch (e) {
      debugPrint('Video upload error: $e');
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Video upload failed: $e')));
    }
  }

  String _getExtension(String path) {
    final idx = path.lastIndexOf('.');
    if (idx == -1) return '';
    return path.substring(idx);
  }

  Future<void> _sendSticker(String url) async {
    try {
      final db = FirebaseFirestore.instance;
      final messagesRef = db
          .collection('conversations')
          .doc(widget.conversationId)
          .collection('messages');
      await messagesRef.add({
        'senderId':
            Provider.of<ChatProvider>(context, listen: false).user?.uid ?? '',
        'text': '',
        'imageUrl': url,
        'sticker': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await db.collection('conversations').doc(widget.conversationId).set({
        'lastMessage': '[sticker]',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _scrollToBottomDelayed();
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Send sticker failed: $e')));
    }
  }

  Future<void> _startRecording() async {
    try {
      final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission denied')),
          );
        }
        return;
      }

      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';

      await _recorder.start(
        const rec.RecordConfig(
          encoder: rec.AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );

      setState(() {
        _isRecording = true;
        _recordPath = path;
      });

      _recordStopwatch = Stopwatch()..start();
      _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        setState(() {}); // refresh elapsed shown in UI
      });
    } catch (e, st) {
      debugPrint('Record start error: $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Record failed: $e')));
      }
    }
  }

  Future<void> _stopRecordingAndSend() async {
    try {
      final path = await _recorder.stop();
      setState(() => _isRecording = false);
      _recTimer?.cancel();
      _recordStopwatch?.stop();

      if (path == null) {
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recording was not saved')),
          );
        return;
      }

      final file = File(path);
      if (!file.existsSync()) {
        if (context.mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Record file not found')),
          );
        return;
      }

      final pathInStorage =
          'chat_audio/${widget.conversationId}/${DateTime.now().millisecondsSinceEpoch}.m4a';

      try {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Uploading voice message...')),
          );
        }

        final url = await _uploadFileAndGetUrl(
          file,
          pathInStorage,
          onProgress: (p) {
            // could update a UI element with progress
          },
        );

        debugPrint(
          'Voice upload completed. storagePath=$pathInStorage url=$url',
        );

        final db = FirebaseFirestore.instance;
        final messagesRef = db
            .collection('conversations')
            .doc(widget.conversationId)
            .collection('messages');
        await messagesRef.add({
          'senderId':
              Provider.of<ChatProvider>(context, listen: false).user?.uid ?? '',
          'text': '',
          'audioUrl': url,
          'createdAt': FieldValue.serverTimestamp(),
        });
        await db.collection('conversations').doc(widget.conversationId).set({
          'lastMessage': '[voice]',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        _scrollToBottomDelayed();

        if (context.mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
        }
      } catch (e, st) {
        debugPrint('Stop recording error: $e\n$st');
        if (context.mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Send voice failed: $e')));
      }
    } catch (e, st) {
      debugPrint('Stop recording error: $e\n$st');
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Send voice failed: $e')));
    }
  }

  Future<void> _playAudio(String url) async {
    if (url.trim().isEmpty) {
      debugPrint('playAudio called with empty url');
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Audio URL is empty')));
      return;
    }

    try {
      if (!(url.startsWith('http://') || url.startsWith('https://'))) {
        debugPrint('playAudio: url does not look like http(s): $url');
      }

      if (_playing && _playingUrl == url) {
        await _player.stop();
        setState(() {
          _playing = false;
          _playingUrl = null;
        });
        return;
      }

      if (_playing) {
        await _player.stop();
      }

      setState(() {
        _playing = true;
        _playingUrl = url;
        _playProgress = Duration.zero;
        _playDuration = Duration.zero;
      });

      await _player.play(UrlSource(url));
    } catch (e, st) {
      debugPrint('Play error: $e\n$st');
      setState(() {
        _playing = false;
        _playingUrl = null;
      });
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Play failed: $e')));
    }
  }

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _AttachmentTile(
              icon: Icons.photo,
              label: 'Photo',
              onTap: () {
                Navigator.of(ctx).pop();
                _pickAndSendImage();
              },
            ),
            _AttachmentTile(
              icon: Icons.video_collection,
              label: 'Video',
              onTap: () {
                Navigator.of(ctx).pop();
                _pickAndSendVideo();
              },
            ),
            _AttachmentTile(
              icon: Icons.emoji_emotions_outlined,
              label: 'Sticker',
              onTap: () {
                Navigator.of(ctx).pop();
                _showStickers();
              },
            ),
            _AttachmentTile(
              icon: Icons.mic,
              label: 'Voice',
              onTap: () {
                Navigator.of(ctx).pop();
                _showRecordingSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showStickers() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Container(
        height: 260,
        padding: const EdgeInsets.all(12),
        child: GridView.count(
          crossAxisCount: 4,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: _stickers.map((s) {
            return GestureDetector(
              onTap: () {
                Navigator.of(ctx).pop();
                _sendSticker(s);
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  s,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, st) {
                    return Container(color: Colors.grey[300]);
                  },
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showRecordingSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (c, setS) {
          String elapsed() {
            final sw = _recordStopwatch;
            if (sw == null) return '00:00';
            final s = sw.elapsed.inSeconds;
            final mm = (s ~/ 60).toString().padLeft(2, '0');
            final ss = (s % 60).toString().padLeft(2, '0');
            return '$mm:$ss';
          }

          return Container(
            padding: const EdgeInsets.all(16),
            height: 200,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isRecording)
                      Row(
                        children: [
                          const Icon(Icons.circle, color: Colors.red, size: 12),
                          const SizedBox(width: 8),
                          Text(
                            'Recording • ${elapsed()}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      )
                    else
                      const Text(
                        'Start recording',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _isRecording
                          ? null
                          : () async {
                              await _startRecording();
                              setS(() {});
                              setState(() {});
                            },
                      icon: const Icon(Icons.mic),
                      label: const Text('Start'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _isRecording
                          ? () async {
                              await _stopRecordingAndSend();
                              setS(() {});
                              setState(() {});
                              Navigator.of(ctx).pop();
                            }
                          : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop & Send'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Voice messages are short audio clips.'),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMessageTile(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final text = (data['text'] ?? '').toString();
    final imageUrl = (data['imageUrl'] ?? '').toString();
    final audioUrl = (data['audioUrl'] ?? '').toString();
    final videoUrl = (data['videoUrl'] ?? '').toString();
    final senderId = (data['senderId'] ?? '').toString();
    final createdAt = data['createdAt'] as Timestamp?;
    final isMe =
        senderId == Provider.of<ChatProvider>(context, listen: false).user?.uid;

    final bubbleChildren = <Widget>[];

    if (imageUrl.isNotEmpty) {
      bubbleChildren.add(
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            imageUrl,
            width: 220,
            height: 160,
            fit: BoxFit.cover,
            errorBuilder: (c, e, st) => Container(
              width: 220,
              height: 160,
              color: Colors.grey[300],
              child: const Icon(Icons.broken_image),
            ),
          ),
        ),
      );
    }

    if (videoUrl.isNotEmpty) {
      bubbleChildren.add(
        GestureDetector(
          onTap: () {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Open video in external player')),
              );
            }
          },
          child: Container(
            width: 220,
            height: 120,
            color: Colors.black12,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.play_circle_fill, size: 44),
                  SizedBox(height: 6),
                  Text('Play video'),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (audioUrl.isNotEmpty) {
      final playingThis = _playing && _playingUrl == audioUrl;
      bubbleChildren.add(
        GestureDetector(
          onTap: () => _playAudio(audioUrl),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(color: Colors.transparent),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  playingThis ? Icons.stop_circle : Icons.play_circle_fill,
                  color: isMe ? Colors.white : Colors.black87,
                  size: 28,
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Voice message',
                      style: TextStyle(
                        color: isMe ? Colors.white : Colors.black87,
                      ),
                    ),
                    if (playingThis)
                      SizedBox(
                        width: 120,
                        child: LinearProgressIndicator(
                          value: (_playDuration.inMilliseconds == 0)
                              ? 0
                              : _playProgress.inMilliseconds /
                                    _playDuration.inMilliseconds,
                          backgroundColor: isMe
                              ? Colors.white24
                              : Colors.black12,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isMe ? Colors.white : Colors.black87,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (text.isNotEmpty) {
      bubbleChildren.add(
        Text(
          text,
          style: TextStyle(
            color: isMe ? Colors.white : Colors.black87,
            fontSize: 16,
          ),
        ),
      );
    }

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: isMe
            ? const LinearGradient(
                colors: [Color(0xFF0EA5E9), Color(0xFF3B82F6)],
              )
            : null,
        color: isMe ? null : Colors.grey.shade100,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(12),
          topRight: const Radius.circular(12),
          bottomLeft: Radius.circular(isMe ? 12 : 0),
          bottomRight: Radius.circular(isMe ? 0 : 12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...bubbleChildren.map(
            (w) => Padding(padding: const EdgeInsets.only(bottom: 6), child: w),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _timeFromTimestamp(createdAt),
                style: TextStyle(
                  fontSize: 11,
                  color: isMe ? Colors.white70 : Colors.black54,
                ),
              ),
              const SizedBox(width: 6),
              if (isMe)
                Icon(
                  Icons.done_all,
                  size: 14,
                  color: isMe ? Colors.white70 : Colors.black38,
                ),
            ],
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isMe) ...[
            const CircleAvatar(radius: 16, child: Icon(Icons.person, size: 18)),
            const SizedBox(width: 8),
            Flexible(child: bubble),
          ] else ...[
            Flexible(child: bubble),
            const SizedBox(width: 8),
            const CircleAvatar(radius: 16, child: Icon(Icons.person, size: 18)),
          ],
        ],
      ),
    );
  }

  void _scrollToBottomDelayed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = Provider.of<ChatProvider>(context, listen: false);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const CircleAvatar(child: Icon(Icons.group, size: 18)),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.title ?? 'Chat')),
          ],
        ),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
          IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: chat.messagesStream(widget.conversationId),
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return Center(child: Text('Error: ${snapshot.error}'));
                if (snapshot.connectionState == ConnectionState.waiting)
                  return const Center(child: CircularProgressIndicator());
                final docs = (snapshot.data as QuerySnapshot?)?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No messages yet — start the conversation!',
                      style: TextStyle(color: Colors.black54),
                    ),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController.jumpTo(0.0);
                  }
                });
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.only(top: 12, bottom: 12),
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    return _buildMessageTile(d);
                  },
                );
              },
            ),
          ),

          // input area
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Row(
                children: [
                  IconButton(
                    onPressed: _showAttachmentSheet,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () {
                              // emoji picker could be integrated
                            },
                            icon: const Icon(
                              Icons.emoji_emotions_outlined,
                              color: Colors.grey,
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              decoration: const InputDecoration(
                                hintText: 'Type a message',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sendText(),
                            ),
                          ),
                          if (_controller.text.trim().isNotEmpty)
                            IconButton(
                              onPressed: _sending ? null : _sendText,
                              icon: const Icon(
                                Icons.send,
                                color: Colors.blueAccent,
                              ),
                            )
                          else
                            IconButton(
                              onPressed: () async {
                                _showRecordingSheet();
                              },
                              icon: const Icon(Icons.mic, color: Colors.grey),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    onPressed: _pickAndSendImage,
                    icon: const Icon(Icons.photo),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _AttachmentTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 90,
        height: 90,
        child: Column(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: Colors.indigo.shade50,
              child: Icon(icon, color: Colors.indigo, size: 28),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
