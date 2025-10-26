import 'dart:async';
import 'dart:convert';
import 'dart:html'; // Assumes web compilation

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart'; // fallback code highlighting
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:markdown/markdown.dart' as md;

import 'main.dart';

BuildContext? _globalContext;
dynamic initialJsonObject;


/// Gradient used for the left panel behind "Your Conversations"
/// (also applied to the AppBar background).
const leftPanelGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [
    Color(0xFF3949AB),
    Color(0xFF1A237E),
  ],
);


class KeepAliveWrapper extends StatefulWidget {
  final Widget child;

  const KeepAliveWrapper({super.key, required this.child});

  @override
  KeepAliveWrapperState createState() => KeepAliveWrapperState();
}

class KeepAliveWrapperState extends State<KeepAliveWrapper>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class ChatInterface extends StatelessWidget {
  const ChatInterface({super.key});

  @override
  Widget build(BuildContext context) {
    // A modern Material 3 theme with Google Fonts + unified SnackBar style
    return MaterialApp(
      title: 'AiDA | Internal AI Assistant',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        scaffoldBackgroundColor: Colors.grey[100],
        textTheme: GoogleFonts.robotoTextTheme().apply(
          bodyColor: Colors.black87,
          displayColor: Colors.black87,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.grey[200],
          border: OutlineInputBorder(
            borderSide: BorderSide.none,
            borderRadius: BorderRadius.circular(10.0),
          ),
          hintStyle: const TextStyle(
            color: Colors.grey,
            fontSize: 16,
          ),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 2,
          centerTitle: true,
          titleTextStyle: GoogleFonts.roboto(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            textStyle: GoogleFonts.roboto(fontWeight: FontWeight.w500),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10.0),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8.0),
          ),
          contentTextStyle: GoogleFonts.roboto(
            color: Colors.white,
            fontSize: 15,
          ),
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  ChatScreenState createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  bool _isLoading = false;

  // Store all messages (user + assistant)
  final List<Map<String, dynamic>> _messages = [];

  final List<String> _previousQuestions = [];
  final List<String> _previousAnswers = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final StreamController<String> _streamController =
      StreamController.broadcast();

  bool internalCodeBaseRelated = false; // from Settings popup
  bool externalCodeBaseRelated = false; // from Settings popup

  // Whether the currently selected conversation is read-only (shared_with_me).
  bool _currentConversationIsShared = false;

  // Identify who created the current conversation (to display if read-only).
  String _currentConversationOwner = "";

  // Metrics-related fields
  Timer? _metricsTimer;
  int _clusterWideRunningJobs = 0;
  int _thisHostRunningJobs = 0;

  // For managing streaming
  HttpRequest? _ongoingHttpRequest;
  StreamController<String>? _ongoingStreamController;

  // Holds conversation metadata from GET /conversation_list/
  final List<Map<String, dynamic>> _conversationList = [];

  var _currentConversationId = "";

  // Controls whether "Your Conversations" panel is displayed
  bool _isConversationsPanelOpen = true;

  @override
  void initState() {
    super.initState();
    _loadPreviousMessages();
    _fetchConversationHistory();
    _startMetricsPolling();
  }

  @override
  void dispose() {
    _streamController.close();
    _metricsTimer?.cancel();
    super.dispose();
  }

  /// Loads previous messages from `initialJsonObject["previous_messages"]`
  void _loadPreviousMessages() {
    if (initialJsonObject != null &&
        initialJsonObject['previous_messages'] is List) {
      final List prevMessages =
          initialJsonObject['previous_messages'] as List<dynamic>;
      for (var m in prevMessages) {
        if (m is Map<String, dynamic> &&
            m.containsKey('role') &&
            m.containsKey('content')) {
          _messages.add({"role": m['role'], "content": m['content']});
          if (m['role'] == 'user') {
            _previousQuestions.add(m['content']);
          } else if (m['role'] == 'assistant') {
            _previousAnswers.add(m['content']);
          }
        }
      }
    }
  }

  /// Polls metrics every 2 seconds
  void _startMetricsPolling() {
    _metricsTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _fetchMetrics();
    });
  }

  Future<void> _fetchMetrics() async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      final HttpRequest metricsReq = HttpRequest();
      metricsReq.open('POST', "$urlEndPoint/get_metrics/", async: true);
      metricsReq.setRequestHeader('Content-Type', 'application/json');
      metricsReq.setRequestHeader('Authorization', 'Bearer $token');

      final body =
          jsonEncode({"hostname": initialJsonObject?['hostname'] ?? ""});
      metricsReq.send(body);

      await metricsReq.onLoad.first;
      if (metricsReq.status == 200) {
        final response = jsonDecode(metricsReq.responseText!);
        setState(() {
          _clusterWideRunningJobs = response['cluster_wide_running_jobs'] ?? 0;
          _thisHostRunningJobs = response['this_host_running_jobs'] ?? 0;
        });
      } else {
        // invalid/expired → clear & redirect
        await storage.delete(key: 'access_token');
        Future.microtask(() {
          if (mounted) {
            navigatorKey.currentState
                ?.pushNamedAndRemoveUntil('/login', (_) => false);
          }
        });
        throw Exception('Invalid token');
      }
    } catch (e) {
      debugPrint("Error fetching metrics: $e");
    }
  }

  /// Fetches the list of conversation summaries from GET /conversation_list/.
  Future<void> _fetchConversationHistory() async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      const url = "$urlEndPoint/conversation_list/";
      final HttpRequest req = HttpRequest();
      req.open('GET', url, async: true);
      req.setRequestHeader('Content-Type', 'application/json');
      req.setRequestHeader('Authorization', 'Bearer $token');

      req.send();
      await req.onLoad.first;

      if (req.status == 200) {
        final responseData = jsonDecode(req.responseText!);
        if (responseData is List) {
          setState(() {
            _conversationList.clear();
            for (var item in responseData) {
              if (item is Map<String, dynamic>) {
                // item might contain: title, conversation_id, user, shared_with_me, shared_with, etc.
                _conversationList.add(item);
              }
            }
          });
          // If you already have a "previousQuestions" set, pick first conversation?
          if (_currentConversationId.isEmpty && _previousQuestions.isNotEmpty) {
            _currentConversationId = responseData[0]['conversation_id'];
          }
        }
      } else {
        // invalid/expired → clear & redirect
        await storage.delete(key: 'access_token');
        Future.microtask(() {
          if (mounted) {
            navigatorKey.currentState
                ?.pushNamedAndRemoveUntil('/login', (_) => false);
          }
        });
        throw Exception('Invalid token');
      }

      if (_conversationList.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _showIntroPopup());
      }
    } catch (e) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showIntroPopup());
      debugPrint("Error fetching conversation history: $e");
    }
  }

  void _showIntroPopup() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: Container(
            padding: const EdgeInsets.all(24.0),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12.0),
              color: Colors.white,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.memory_rounded,
                  size: 50,
                  color: Colors.indigo.shade700,
                ),
                const SizedBox(height: 15),
                Text(
                  "AI Introduction",
                  style: GoogleFonts.roboto(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  "Would you like to explore more about this AI system?",
                  style: GoogleFonts.roboto(
                    fontSize: 16,
                    color: Colors.black54,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 25),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _sendMessage("Please introduce yourself", false);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.indigo.shade600,
                      ),
                      child: const Text(
                        "Yes",
                        style: TextStyle(fontSize: 16, color: Colors.white),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                      ),
                      child: const Text(
                        "No",
                        style: TextStyle(fontSize: 16, color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSwitchDialog() {
    showCupertinoModalPopup(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return CupertinoAlertDialog(
            title: const Text(
              "Select Option",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        "Is question related to an internal codebase?",
                        style: TextStyle(fontSize: 16),
                        textAlign: TextAlign.left,
                      ),
                    ),
                    CupertinoSwitch(
                      value: internalCodeBaseRelated,
                      onChanged: (bool value) {
                        setDialogState(() => internalCodeBaseRelated = value);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        "Is question related to an imported external codebase?",
                        style: TextStyle(fontSize: 16),
                        textAlign: TextAlign.left,
                      ),
                    ),
                    CupertinoSwitch(
                      value: externalCodeBaseRelated,
                      onChanged: (bool value) {
                        setDialogState(() => externalCodeBaseRelated = value);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
            actions: [
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context),
                child: const Text("Save"),
              ),
            ],
          );
        },
      ),
    );
  }

  void _cancelOngoingRequest() {
    if (_ongoingHttpRequest != null) {
      _ongoingHttpRequest?.abort();
      _ongoingHttpRequest = null;
    }
    if (_ongoingStreamController != null) {
      _ongoingStreamController?.close();
      _ongoingStreamController = null;
    }
    setState(() {
      _isLoading = false;
    });
  }

  bool get _isUserNearBottom {
    if (!_scrollController.hasClients) return false;
    const threshold = 200.0;
    final currentScroll = _scrollController.position.pixels;
    final maxScroll = _scrollController.position.maxScrollExtent;
    return (maxScroll - currentScroll) <= threshold;
  }

  void _scrollToBottomIfNeeded() {
    if (_scrollController.hasClients && _isUserNearBottom) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

  /// Sends message to the server, unless conversation is read-only.
  Future<void> _sendMessage(String message, bool ignoreQuestion) async {
    if (_isLoading) return;
    if (_currentConversationIsShared) {
      debugPrint(
          "User attempted to ask question in a read-only conversation. Ignored.");
      return;
    }
    if (message.trim().isEmpty) return;

    setState(() => _isLoading = true);
    _controller.clear();

    final request = {
      "conversation_id": _currentConversationId,
      "advanced_diagnostic_mode": false,
      "question": message,
      "internal_codebase_related": internalCodeBaseRelated,
      "external_codebase_related": externalCodeBaseRelated,
    };

    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      final HttpRequest req = HttpRequest();
      _ongoingHttpRequest = req;
      req.open('POST', "$urlEndPoint/qa/", async: true);
      req.setRequestHeader('Content-Type', 'application/json');
      req.setRequestHeader('Authorization', 'Bearer $token');

      String collectedResponse = "";
      final StreamController<String> responseStreamController =
          StreamController.broadcast();
      _ongoingStreamController = responseStreamController;

      setState(() {
        if (!ignoreQuestion) {
          _messages.add({"role": "user", "content": message});
          _messages.add({
            "role": "assistant",
            "content": "",
            "streamId": responseStreamController,
          });
        }
        _previousQuestions.add(message);
      });

      req.onReadyStateChange.listen((_) {
        if (req.responseText == null) return;
        if (req.readyState == HttpRequest.LOADING) {
          final newChunk =
              req.responseText!.substring(collectedResponse.length);
          collectedResponse += newChunk;
          setState(() {
            if (_messages.isNotEmpty) {
              _messages.last['content'] = collectedResponse;
            }
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToBottomIfNeeded();
          });
        } else if (req.readyState == HttpRequest.DONE) {
          setState(() {
            if (_messages.isNotEmpty) {
              _messages.last['content'] = collectedResponse;
            }
            _previousAnswers.add(collectedResponse);
            _isLoading = false;
          });
          responseStreamController.close();
          _ongoingHttpRequest = null;
          _ongoingStreamController = null;

          // After new chat completes streaming, refresh conversation list
          _fetchConversationHistory();

          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToBottomIfNeeded();
          });
        }
      });

      req.onError.listen((event) {
        setState(() => _isLoading = false);
        responseStreamController.close();
        _ongoingHttpRequest = null;
        _ongoingStreamController = null;
        _handleError("Network error: Could not connect to the server.");
      });

      req.send(jsonEncode(request));
    } catch (e) {
      _handleError(e.toString());
      setState(() => _isLoading = false);
    }
  }

  /// Retrieves a specific conversation’s messages by ID via POST /conversation/.
  Future<void> _fetchChatHistory(String conversationId) async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      const url = "$urlEndPoint/conversation/";
      final HttpRequest req = HttpRequest();

      req.open('POST', url, async: true);
      req.setRequestHeader('Content-Type', 'application/json');
      req.setRequestHeader('Authorization', 'Bearer $token');

      req.send(jsonEncode({"conversation_id": conversationId}));

      await req.onLoad.first;
      if (req.status == 200) {
        final responseData = jsonDecode(req.responseText!);
        final List messages = responseData;

        setState(() {
          _currentConversationId = conversationId;
          _messages.clear();
          _previousQuestions.clear();
          _previousAnswers.clear();
          // Keep _currentConversationIsShared as is
          // Keep _currentConversationOwner as is

          for (var m in messages) {
            final role = m['role'];
            final content = m['content'];
            final eq = m['enhanced_question'];

            if (role != null && content != null) {
              if (role == 'user' && eq != null) {
                _messages.add({
                  "role": "user",
                  "content": content,
                  "enhanced_question": eq,
                });
              } else {
                _messages.add({"role": role, "content": content});
              }

              if (role == 'user') {
                _previousQuestions.add(content);
              } else if (role == 'assistant') {
                _previousAnswers.add(content);
              }
            }
          }
        });
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      } else {
        debugPrint("Failed to fetch chat history. Status: ${req.status}");

        // invalid/expired → clear & redirect
        await storage.delete(key: 'access_token');
        Future.microtask(() {
          if (mounted) {
            navigatorKey.currentState
                ?.pushNamedAndRemoveUntil('/login', (_) => false);
          }
        });
        throw Exception('Invalid token');
      }
    } catch (e) {
      debugPrint("Error fetching chat history: $e");
    }
  }

  /// Deletes the conversation only if not read-only.
  Future<void> _deleteConversation(String conversationId) async {
    if (_currentConversationIsShared) {
      debugPrint(
          "Attempted to delete a read-only conversation. Doing nothing.");
      return;
    }
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      const url = "$urlEndPoint/delete_conversation/";
      final HttpRequest req = HttpRequest();
      req.open('POST', url, async: true);
      req.setRequestHeader('Content-Type', 'application/json');
      req.setRequestHeader('Authorization', 'Bearer $token');

      req.send(jsonEncode({"conversation_id": conversationId}));

      await req.onLoad.first;
      if (req.status == 200) {
        debugPrint("Successfully deleted conversation: $conversationId");
        if (_currentConversationId == conversationId) {
          setState(() {
            _currentConversationId = "";
            _messages.clear();
            _previousQuestions.clear();
            _previousAnswers.clear();
            _currentConversationIsShared = false;
            _currentConversationOwner = "";
          });
        }
        // Remove it locally
        setState(() {
          _conversationList.removeWhere(
            (conv) => conv['conversation_id'] == conversationId,
          );
        });
      } else {
        debugPrint(
            "Failed to delete conversation $conversationId. Status: ${req.status}");
        // invalid/expired → clear & redirect
        await storage.delete(key: 'access_token');
        Future.microtask(() {
          if (mounted) {
            navigatorKey.currentState
                ?.pushNamedAndRemoveUntil('/login', (_) => false);
          }
        });
        throw Exception('Invalid token');
      }
    } catch (e) {
      debugPrint("Error deleting conversation: $e");
    }
  }

  /// A single "Share" call which takes the final list of usernames to share with (add/remove).
  Future<void> _shareConversation(
      String conversationId, List<String> userNames) async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      const url = "$urlEndPoint/share_with/";
      final HttpRequest req = HttpRequest();
      req.open('POST', url, async: true);
      req.setRequestHeader('Content-Type', 'application/json');
      req.setRequestHeader('Authorization', 'Bearer $token');

      // Build the request body:
      // {
      //   "conversation_id": str,
      //   "shared_with": [ {"user": str}, ... ]
      // }
      final body = {
        "conversation_id": conversationId,
        "shared_with": userNames.map((u) => {"user": u}).toList(),
      };

      req.send(jsonEncode(body));
      await req.onLoad.first;

      if (req.status == 200) {
        // Show a success message (theme-based SnackBar style)
        if (_globalContext != null) {
          ScaffoldMessenger.of(_globalContext!).showSnackBar(
            const SnackBar(
              content: Text("Conversation sharing updated successfully!"),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 2),
            ),
          );
        }
        // Refresh conversation list (to see updated share info)
        _fetchConversationHistory();
      } else {
        debugPrint("Failed to share conversation. Status: ${req.status}");
        if (_globalContext != null) {
          ScaffoldMessenger.of(_globalContext!).showSnackBar(
            SnackBar(
              content: Text(
                "Error: Could not update share list. Status: ${req.status}",
              ),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        debugPrint(
            "Failed to delete conversation $conversationId. Status: ${req.status}");
        // invalid/expired → clear & redirect
        await storage.delete(key: 'access_token');
        Future.microtask(() {
          if (mounted) {
            navigatorKey.currentState
                ?.pushNamedAndRemoveUntil('/login', (_) => false);
          }
        });
        throw Exception('Invalid token');
      }
    } catch (e) {
      debugPrint("Error sharing conversation: $e");
      if (_globalContext != null) {
        ScaffoldMessenger.of(_globalContext!).showSnackBar(
          SnackBar(
            content: Text("Error: $e"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// OPTIONAL: If you have a dedicated urlEndPoint to remove yourself from shares
  Future<void> _unshareWithMe(String conversationId) async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      const String url = "$urlEndPoint/unshare_with_me/";
      final HttpRequest req = HttpRequest();
      req.open('POST', url, async: true);
      req.setRequestHeader('Content-Type', 'application/json');
      req.setRequestHeader('Authorization', 'Bearer $token');

      req.send(jsonEncode({"conversation_id": conversationId}));

      await req.onLoad.first;

      if (req.status == 200) {
        if (_globalContext != null) {
          ScaffoldMessenger.of(_globalContext!).showSnackBar(
            const SnackBar(
              content: Text("You are no longer shared on this conversation."),
              backgroundColor: Colors.green,
            ),
          );
        }
        // If you want to clear out the chat if it was the current conversation:
        if (_currentConversationId == conversationId) {
          setState(() {
            _currentConversationId = "";
            _messages.clear();
            _previousQuestions.clear();
            _previousAnswers.clear();
            _currentConversationIsShared = false;
            _currentConversationOwner = "";
          });
        }
        setState(() {
          _conversationList.removeWhere(
            (conv) => conv['conversation_id'] == conversationId,
          );
        });
      } else {
        debugPrint("Failed to unshare with me. Status: ${req.status}");
        if (_globalContext != null) {
          ScaffoldMessenger.of(_globalContext!).showSnackBar(
            SnackBar(
              content: Text("Error: Could not unshare. Status: ${req.status}"),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        await storage.delete(key: 'access_token');
        Future.microtask(() {
          if (mounted) {
            navigatorKey.currentState
                ?.pushNamedAndRemoveUntil('/login', (_) => false);
          }
        });
        throw Exception('Invalid token');
      }
    } catch (e) {
      debugPrint("Error unsharing conversation: $e");
      if (_globalContext != null) {
        ScaffoldMessenger.of(_globalContext!).showSnackBar(
          SnackBar(
            content: Text("Error: $e"),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Shows a dialog with a chip-style input list for "shared_with" usernames.
  /// Only accessible if NOT read-only.
  void _showShareConversationDialog(
    String conversationId,
    List<String> initialShares,
  ) {
    final TextEditingController chipInputController = TextEditingController();
    final List<String> shareChips = List.from(initialShares);

    showDialog(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16.0),
          ),
          title: Text(
            "Share Conversation",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Theme.of(context).primaryColor,
            ),
          ),
          content: StatefulBuilder(
            builder: (BuildContext context, setState) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Add or remove usernames below, then press Save.",
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Display chips
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      children: shareChips.map((username) {
                        return Chip(
                          label: Text(
                            username,
                            style: const TextStyle(fontSize: 14),
                          ),
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .secondary
                              .withOpacity(0.2),
                          deleteIconColor: Theme.of(context).primaryColorDark,
                          onDeleted: () {
                            setState(() {
                              shareChips.remove(username);
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    // Text field for adding new usernames
                    TextField(
                      controller: chipInputController,
                      decoration: InputDecoration(
                        hintText: "Type a username, then press ENTER",
                        fillColor: Colors.grey[200],
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8.0),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12.0,
                          vertical: 10.0,
                        ),
                      ),
                      onSubmitted: (value) {
                        final trimmed = value.trim();
                        if (trimmed.isNotEmpty &&
                            !shareChips.contains(trimmed)) {
                          setState(() => shareChips.add(trimmed));
                        }
                        chipInputController.clear();
                      },
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _shareConversation(conversationId, shareChips);
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  void _handleError(Object error) {
    String errorMessage = (error is ProgressEvent)
        ? (error.target as HttpRequest).statusText ?? 'Unknown error'
        : error.toString();

    setState(() {
      _messages.add({
        "role": "assistant",
        "content": "Error: Unable to fetch response. $errorMessage"
      });
    });
    _streamController.close();
  }

  Widget _buildMessage(Map<String, dynamic> message) {
    final bool isUserMessage = message['role'] == 'user';
    if (isUserMessage) {
      return _buildUserMessageContainer(
        message['content'] ?? "",
        enhancedQuestion: message['enhanced_question'],
      );
    } else {
      if (message.containsKey('streamId') &&
          message['streamId'] is StreamController<String>) {
        return StreamBuilder<String>(
          stream: (message['streamId'] as StreamController<String>).stream,
          builder: (context, snapshot) {
            if (message['content'].isNotEmpty) {
              return _buildAssistantMessageContainer(message['content']);
            }
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return _buildLoadingIndicator();
            } else {
              return _buildAssistantMessageContainer(snapshot.data ?? "");
            }
          },
        );
      } else {
        return _buildAssistantMessageContainer(message['content'] ?? "");
      }
    }
  }

  Widget _buildUserMessageContainer(String content,
      {String? enhancedQuestion}) {
    if (enhancedQuestion == null) {
      return _buildMessageContainer(
        alignment: Alignment.centerRight,
        color: Colors.indigo.shade100,
        content: content,
        showCopyButton: false,
        useMarkdown: true,
      );
    }
    // If there's an enhanced question, show it as an iMessage-like "reply"
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _buildMessageContainer(
          alignment: Alignment.centerRight,
          color: Colors.indigo.shade100,
          content: content,
          showCopyButton: false,
          useMarkdown: true,
        ),
        const SizedBox(height: 4),
        Container(
          margin: const EdgeInsets.only(right: 16.0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16.0),
            child: Container(
              color: Colors.grey.shade200,
              padding:
                  const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
              child: Text(
                enhancedQuestion,
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAssistantMessageContainer(String content) {
    return _buildMessageContainer(
      alignment: Alignment.centerLeft,
      color: Colors.white,
      content: content,
      showCopyButton: true,
      useMarkdown: true,
    );
  }

  Widget _buildMessageContainer({
    required Alignment alignment,
    required Color color,
    required String content,
    required bool showCopyButton,
    required bool useMarkdown,
  }) {
    return Container(
      alignment: alignment,
      margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 6,
                offset: const Offset(2, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(
                  left: 16.0,
                  right: showCopyButton ? 50.0 : 16.0,
                  top: 12.0,
                  bottom: showCopyButton ? 40.0 : 12.0,
                ),
                child: useMarkdown
                    ? MarkdownBody(
                        data: content,
                        selectable: true,
                        styleSheet: markdownStyleSheet,
                        builders: {
                          'pre': CodeElementBuilder(),
                          'code': CodeElementBuilder(),
                        },
                      )
                    : SelectableText(
                        content,
                        style: GoogleFonts.roboto(
                          color: Colors.black87,
                          fontSize: 15.0,
                          height: 1.4,
                        ),
                      ),
              ),
              if (showCopyButton)
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    tooltip: "Copy this message",
                    onPressed: () => _copyMessage(content),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 6,
            offset: const Offset(2, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 20.0,
            height: 20.0,
            child: CircularProgressIndicator(
              strokeWidth: 2.0,
              color: Colors.indigo,
            ),
          ),
          const SizedBox(width: 10.0),
          Text(
            "Generating a response...",
            style: GoogleFonts.roboto(
              color: Colors.black87,
              fontSize: 15.0,
            ),
          ),
        ],
      ),
    );
  }

  void _copyMessage(String content) {
    Clipboard.setData(ClipboardData(text: content)).then((_) {
      if (_globalContext != null) {
        ScaffoldMessenger.of(_globalContext!).showSnackBar(
          const SnackBar(
            content: Text("Message copied!"),
            backgroundColor: Colors.indigo,
            duration: Duration(seconds: 2),
          ),
        );
      }
    });
  }

  final markdownStyleSheet = MarkdownStyleSheet(
    p: GoogleFonts.roboto(
      color: Colors.black87,
      fontSize: 15.0,
      height: 1.4,
    ),
    code: GoogleFonts.robotoMono(
      color: Colors.black87,
      backgroundColor: Colors.grey.shade200,
      fontSize: 14.0,
    ),
    blockquote: TextStyle(
      color: Colors.grey.shade700,
      fontStyle: FontStyle.italic,
    ),
    a: const TextStyle(
      color: Colors.blueAccent,
      decoration: TextDecoration.underline,
    ),
  );

  @override
  Widget build(BuildContext context) {
    _globalContext = context;

    // Group conversations by month
    final DateFormat monthYearFormat = DateFormat('MMMM yyyy');
    final Map<String, List<Map<String, dynamic>>> groupedConversations = {};

    for (var conv in _conversationList) {
      final tsString = conv["timestamp"] as String?;
      if (tsString == null) {
        groupedConversations.putIfAbsent("Unknown Date", () => []).add(conv);
        continue;
      }

      DateTime? parsedDate;
      try {
        parsedDate = DateTime.parse(tsString);
      } catch (_) {
        parsedDate = null;
      }

      String monthYearKey = "Unknown Date";
      if (parsedDate != null) {
        monthYearKey = monthYearFormat.format(parsedDate);
      }

      groupedConversations.putIfAbsent(monthYearKey, () => []).add(conv);
    }

    final sortedGroupKeys = groupedConversations.keys.toList()
      ..sort((a, b) {
        DateTime dateA;
        DateTime dateB;
        try {
          dateA = monthYearFormat.parse(a);
        } catch (_) {
          dateA = DateTime(1900);
        }
        try {
          dateB = monthYearFormat.parse(b);
        } catch (_) {
          dateB = DateTime(1900);
        }
        return dateB.compareTo(dateA);
      });

    return Scaffold(
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: leftPanelGradient,
          ),
        ),
        leading: IconButton(
          tooltip: _isConversationsPanelOpen
              ? "Fold Conversations"
              : "Unfold Conversations",
          icon: Icon(
            _isConversationsPanelOpen ? Icons.menu_open : Icons.menu,
            color: Colors.white,
          ),
          onPressed: () {
            setState(() {
              _isConversationsPanelOpen = !_isConversationsPanelOpen;
            });
          },
        ),
        // title: Row(
        //   mainAxisSize: MainAxisSize.min,
        //   children: [
        //     const GradientLogo(),
        //     const SizedBox(width: 8),
        //     Column(
        //       children: [
        //         ShaderMask(
        //           blendMode: BlendMode.srcIn,
        //           shaderCallback: (Rect bounds) {
        //             return gradientForText.createShader(bounds);
        //           },
        //           child: Text(
        //             'AiDA',
        //             style: GoogleFonts.sora(
        //               fontSize: 20,
        //               fontWeight: FontWeight.bold,
        //             ),
        //           ),
        //         ),
        //         const Divider(height: 1),
        //         ShaderMask(
        //           blendMode: BlendMode.srcIn,
        //           shaderCallback: (Rect bounds) {
        //             return gradientForText.createShader(bounds);
        //           },
        //           child: Text(
        //             'Internal AI Assistant',
        //             style: GoogleFonts.roboto(
        //               fontSize: 20,
        //               fontWeight: FontWeight.bold,
        //             ),
        //           ),
        //         ),
        //       ],
        //     ),
        //   ],
        // ),
        actions: [
          Tooltip(
            message: 'AI Work Queue: Current and Cluster-Wide Running Jobs',
            child: Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6.0,
                    vertical: 4.0,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.smart_toy, size: 16, color: Colors.grey[700]),
                      const SizedBox(width: 4),
                      Text(
                        'AI Work Queue: ',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (child, animation) =>
                            FadeTransition(opacity: animation, child: child),
                        child: Text(
                          '$_thisHostRunningJobs / $_clusterWideRunningJobs',
                          key: ValueKey<String>(
                            '$_thisHostRunningJobs / $_clusterWideRunningJobs',
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[800],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.home),
            onPressed: () => {
              navigatorKey.currentState
                  ?.pushNamedAndRemoveUntil('/navigation', (_) => false)
            },
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white),
            tooltip: "About AI Insights",
            onPressed: () {
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12.0)),
                    title: Text(
                      'About AI Insights',
                      style: GoogleFonts.roboto(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                    content: Text(
                      'This application uses cutting-edge AI technology to provide actionable insights from your internal data.',
                      style: GoogleFonts.roboto(
                        fontSize: 16,
                        color: Colors.black87,
                        height: 1.4,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.indigo.shade700,
                        ),
                        child: const Text('Close'),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            width: _isConversationsPanelOpen ? 300 : 0,
            child: _isConversationsPanelOpen
                ? Container(
                    decoration: const BoxDecoration(
                      gradient: leftPanelGradient,
                      borderRadius: BorderRadius.only(
                        topRight: Radius.circular(24.0),
                        bottomRight: Radius.circular(24.0),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 8.0,
                          offset: Offset(2, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Container(
                          margin: const EdgeInsets.only(bottom: 24.0),
                          padding: const EdgeInsets.all(16.0),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(16.0),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  "Your Conversations",
                                  style: GoogleFonts.roboto(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Create New Chat
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: ElevatedButton.icon(
                            onPressed: () {
                              setState(() {
                                _currentConversationId = "";
                                _messages.clear();
                                _previousQuestions.clear();
                                _previousAnswers.clear();
                                _currentConversationIsShared = false;
                                _currentConversationOwner = "";
                              });
                            },
                            icon: const Icon(Icons.chat_bubble_outline,
                                color: Colors.white),
                            label: const Text(
                              "Create New Chat",
                              style: TextStyle(color: Colors.white),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white.withOpacity(0.1),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              ),
                              padding: const EdgeInsets.all(12.0),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        // Conversation list
                        Expanded(
                          child: SingleChildScrollView(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12.0),
                            child: Column(
                              children: sortedGroupKeys.map((heading) {
                                final convList = groupedConversations[heading]!;
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8.0),
                                  child: Theme(
                                    data: ThemeData().copyWith(
                                      dividerColor: Colors.transparent,
                                      textTheme: TextTheme(
                                        titleMedium: GoogleFonts.roboto(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      iconTheme: const IconThemeData(
                                          color: Colors.white),
                                      dividerTheme: const DividerThemeData(
                                        color: Colors.white54,
                                      ),
                                    ),
                                    child: ExpansionTile(
                                      initiallyExpanded: true,
                                      iconColor: Colors.white,
                                      collapsedIconColor: Colors.white,
                                      collapsedBackgroundColor:
                                          Colors.white.withOpacity(0.07),
                                      backgroundColor:
                                          Colors.white.withOpacity(0.07),
                                      title: _buildConversationHeading(heading),
                                      children: convList.map((convItem) {
                                        return _buildConversationItem(
                                          convItem: convItem,
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : null,
          ),
          // Main chat area
          Expanded(
            child: Column(
              children: [
                // If there are no messages, show a friendly greeting
                Expanded(
                  child: _messages.isEmpty
                      ? Center(
                          child: Text(
                            "Hi there! Ask me anything or pick a conversation from the left.",
                            style: GoogleFonts.roboto(
                              fontSize: 18,
                              color: Colors.grey[700],
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10.0, vertical: 8.0),
                          itemCount: _messages.length,
                          itemBuilder: (BuildContext context, int index) {
                            return KeepAliveWrapper(
                              child: _buildMessage(_messages[index]),
                            );
                          },
                        ),
                ),
                // Bottom input area
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      // The text field hint changes if read-only => show owner
                      Expanded(
                        child: RawKeyboardListener(
                          focusNode: FocusNode(),
                          onKey: (RawKeyEvent event) {
                            if (_currentConversationIsShared) {
                              // do nothing
                              return;
                            }
                            if (event is RawKeyDownEvent &&
                                event.logicalKey == LogicalKeyboardKey.enter) {
                              if (event.isShiftPressed) {
                                final newText = '${_controller.text}\n';
                                _controller.value = TextEditingValue(
                                  text: newText,
                                  selection: TextSelection.fromPosition(
                                    TextPosition(offset: newText.length),
                                  ),
                                );
                              } else {
                                final textToSend = _controller.text.trim();
                                if (textToSend.isNotEmpty) {
                                  _sendMessage(textToSend, false);
                                  _controller.clear();
                                }
                              }
                            }
                          },
                          child: TextField(
                            controller: _controller,
                            enabled: !_currentConversationIsShared,
                            autocorrect: true,
                            enableSuggestions: true,
                            maxLines: 25,
                            minLines: 1,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.none,
                            style: GoogleFonts.roboto(
                              color: _currentConversationIsShared
                                  ? Colors.grey
                                  : Colors.black87,
                            ),
                            decoration: InputDecoration(
                              hintText: _currentConversationIsShared
                                  ? 'Shared conversation by $_currentConversationOwner (read-only)'
                                  : 'Enter your question...',
                              suffixIcon: IconButton(
                                icon: Icon(
                                  Icons.send,
                                  color: _currentConversationIsShared
                                      ? Colors.grey
                                      : Colors.indigo.shade700,
                                ),
                                onPressed:
                                    _isLoading || _currentConversationIsShared
                                        ? null
                                        : () => _sendMessage(
                                              _controller.text.trim(),
                                              false,
                                            ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_isLoading)
                        ElevatedButton(
                          onPressed: _cancelOngoingRequest,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade600,
                          ),
                          child: const Text(
                            "Cancel",
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.settings),
                        color: Colors.indigo.shade700,
                        onPressed: _showSwitchDialog,
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationHeading(String text) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: GoogleFonts.roboto(
          color: Colors.white70,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }

  void _showConversationContextMenu(
    Offset tapPosition, {
    required String conversationId,
    required bool isSharedWithMe,
    required List<String> sharedWithList,
  }) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        tapPosition.dx,
        tapPosition.dy,
        tapPosition.dx,
        tapPosition.dy,
      ),
      items: isSharedWithMe
          ? const [
              PopupMenuItem<String>(
                value: 'unshare_me',
                child: Row(
                  children: [
                    Icon(Icons.exit_to_app, color: Colors.red),
                    SizedBox(width: 8),
                    Text("Unshare with Me"),
                  ],
                ),
              ),
            ]
          : [
              const PopupMenuItem<String>(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.person_add, color: Colors.indigo),
                    SizedBox(width: 8),
                    Text("Share"),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete, color: Colors.red),
                    SizedBox(width: 8),
                    Text("Delete"),
                  ],
                ),
              ),
            ],
    );

    switch (selected) {
      case 'share':
        _showShareConversationDialog(conversationId, sharedWithList);
        break;
      case 'delete':
        _deleteConversation(conversationId);
        break;
      case 'unshare_me':
        _unshareWithMe(conversationId);
        break;
      default:
        break;
    }
  }

  /// Renders a conversation item. If shared_with_me == true => read-only,
  /// hide Share/Delete. Show only "Unshare with me" popup item, if wanted.
  Widget _buildConversationItem({required Map<String, dynamic> convItem}) {
    final String conversationId = convItem["conversation_id"];
    final String title = convItem["title"] ?? "Untitled";
    final String emoji = convItem["emoji"] ?? "💬";
    final bool isSharedWithMe = convItem["shared_with_me"] == true;

    final String createdBy = convItem["user"] ?? ""; // The conversation creator

    // If "shared_with" is present, it's a list of objects: [ {"user": "someName"}, ... ]
    // We only extract the "user" key if present. Otherwise empty.
    final List<String> sharedWithList = (convItem["shared_with"] as List?)
            ?.where(
                (obj) => obj is Map<String, dynamic> && obj.containsKey("user"))
            .map((obj) => obj["user"].toString())
            .toList() ??
        [];

    return InkWell(
      onTap: () {
        if (_isLoading) return; // guard
        _currentConversationId = conversationId;
        _currentConversationIsShared = isSharedWithMe;
        _currentConversationOwner = createdBy;

        _fetchChatHistory(conversationId);
      },
      // NEW: right‑click (secondary tap) opens context menu
      onSecondaryTapDown: (details) => _showConversationContextMenu(
        details.globalPosition,
        conversationId: conversationId,
        isSharedWithMe: isSharedWithMe,
        sharedWithList: sharedWithList,
      ),
      child: Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 10.0),
        decoration: BoxDecoration(
          color: conversationId == _currentConversationId
              ? Colors.white.withOpacity(0.25)
              : Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            if (isSharedWithMe || sharedWithList.isNotEmpty) ...[
              const Icon(Icons.people, color: Colors.white, size: 18),
              const SizedBox(width: 4),
            ],
            Text(
              emoji,
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: GoogleFonts.roboto(
                  color: Colors.white,
                  fontWeight: FontWeight.normal,
                  fontSize: 14,
                ),
              ),
            ),
            // Keep the three‑dot button for hover/touch devices
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white),
              onSelected: (value) {
                if (value == 'share') {
                  _showShareConversationDialog(conversationId, sharedWithList);
                } else if (value == 'delete') {
                  _deleteConversation(conversationId);
                } else if (value == 'unshare_me') {
                  _unshareWithMe(conversationId);
                }
              },
              itemBuilder: (BuildContext context) {
                if (isSharedWithMe) {
                  return const [
                    PopupMenuItem<String>(
                      value: 'unshare_me',
                      child: Row(
                        children: [
                          Icon(Icons.exit_to_app, color: Colors.red),
                          SizedBox(width: 8),
                          Text("Unshare with Me"),
                        ],
                      ),
                    ),
                  ];
                } else {
                  return [
                    const PopupMenuItem<String>(
                      value: 'share',
                      child: Row(
                        children: [
                          Icon(Icons.person_add, color: Colors.indigo),
                          SizedBox(width: 8),
                          Text("Share"),
                        ],
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete, color: Colors.red),
                          SizedBox(width: 8),
                          Text("Delete"),
                        ],
                      ),
                    ),
                  ];
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A custom MarkdownElementBuilder to handle code blocks with a "Copy Code" button.
class CodeElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? style) {
    // For triple-backtick fenced code blocks
    if (element.tag == 'pre') {
      final codeElement = element.children?.first;
      if (codeElement is md.Element && codeElement.tag == 'code') {
        return _buildCodeBlockWithCopy(codeElement.textContent);
      }
    }
    // For inline `code` blocks
    if (element.tag == 'code') {
      return Container(
        decoration: BoxDecoration(color: Colors.grey.shade200),
        child: SelectableText(
          element.textContent,
          style: GoogleFonts.robotoMono(
            fontSize: 14.0,
            color: Colors.black87,
          ),
        ),
      );
    }
    return null;
  }

  Widget _buildCodeBlockWithCopy(String code) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          color: Colors.grey.shade200,
          padding: const EdgeInsets.all(8.0),
          child: HighlightView(
            code,
            language: _detectLanguage(code),
            theme: githubTheme,
            textStyle: GoogleFonts.robotoMono(fontSize: 14.0),
          ),
        ),
        Container(
          color: Colors.grey.shade200,
          padding: const EdgeInsets.only(right: 8.0, bottom: 8.0),
          child: Align(
            alignment: Alignment.bottomRight,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.grey.shade300,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
              ),
              icon: const Icon(Icons.copy, size: 16.0, color: Colors.black87),
              label: const Text(
                "Copy Code",
                style: TextStyle(fontSize: 14.0, color: Colors.black87),
              ),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code)).then((_) {
                  if (_globalContext != null) {
                    ScaffoldMessenger.of(_globalContext!).showSnackBar(
                      const SnackBar(
                        content: Text("Copied to clipboard!"),
                        backgroundColor: Colors.indigo,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  String _detectLanguage(String code) {
    if (code.contains('class') && code.contains('void main()')) return 'dart';
    if (code.contains('function') || code.contains('console.log')) {
      return 'javascript';
    }
    if (code.contains('def ') || code.contains('print(')) return 'python';
    if (code.contains('import ') || code.contains('public class')) {
      return 'java';
    }
    if (code.contains('#include') || code.contains('std::')) return 'cpp';
    if (code.trim().startsWith('{') && code.trim().endsWith('}')) return 'json';
    if (code.contains('<html') || code.contains('<body')) return 'html';
    if (code.contains('SELECT ') || code.contains('INSERT INTO')) return 'sql';
    if (code.contains('echo ') || code.contains('#!/bin/bash')) return 'bash';
    if (code.contains('body {') || code.contains('color:')) return 'css';
    if (code.contains(': ') &&
        !code.contains('function') &&
        !code.contains('class')) {
      return 'yaml';
    }
    return 'plaintext';
  }
}
