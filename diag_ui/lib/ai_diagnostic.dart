import 'dart:async';
import 'dart:convert';

import 'package:advanced_ai_diagnostics/ui_elements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'main.dart';

var headers = {
  "Content-Type": "application/json",
  "Accept": "application/json",
};

/// A dark theme, with a transparent scaffold background.
final ThemeData creativeColorTheme = ThemeData(
  brightness: Brightness.dark,
  primarySwatch: Colors.deepPurple,
  scaffoldBackgroundColor: Colors.transparent,
  textTheme: GoogleFonts.robotoTextTheme(
    ThemeData.dark().textTheme,
  ).apply(
    bodyColor: Colors.white,
    displayColor: Colors.white,
  ),
);

// ----------------------------------------------------------------------
// Models
// ----------------------------------------------------------------------

class CategoryModel {
  final String name;
  final int count;

  CategoryModel({required this.name, required this.count});
}

class AnalysisIteration {
  final String description;
  final String command;

  const AnalysisIteration({
    required this.description,
    required this.command,
  });
}

class Acknowledgement {
  final String user;
  final String timestamp;

  const Acknowledgement({required this.user, required this.timestamp});
}

class ResolutionStatus {
  final String user;
  final String timestamp;

  const ResolutionStatus({required this.user, required this.timestamp});
}

class CanceledProcess {
  final String user;
  final String timestamp;

  const CanceledProcess({required this.user, required this.timestamp});
}

class AdvancedDiagnosticConfig {
  final String environment;
  final String project;
  final String trackingId;
  final String hostname;
  final String program;

  const AdvancedDiagnosticConfig({
    required this.environment,
    required this.project,
    required this.trackingId,
    required this.hostname,
    required this.program,
  });
}

class AdvancedDiagnosticData {
  final List<AnalysisIteration> iterations;
  final String originalProblem;
  final AdvancedDiagnosticConfig config;
  final String timestamp;
  final String? finalFixDescription;
  final List<Acknowledgement> acknowledgements;
  final ResolutionStatus? resolutionStatus;
  final bool complete;
  final CanceledProcess? canceledProcess;
  final List<String> categories;
  final String? lastUpdated;

  const AdvancedDiagnosticData({
    required this.iterations,
    required this.originalProblem,
    required this.config,
    required this.timestamp,
    required this.finalFixDescription,
    required this.acknowledgements,
    required this.resolutionStatus,
    required this.complete,
    required this.canceledProcess,
    required this.categories,
    this.lastUpdated,
  });

  // The last iteration's description is considered the 'root cause'
  String get rootCause => iterations.isNotEmpty
      ? iterations.last.description
      : "No root cause found";

  // If resolutionStatus != null, we consider it resolved
  bool get isResolved => resolutionStatus != null;
}

// ----------------------------------------------------------------------
// Main App
// ----------------------------------------------------------------------

class CreativeColorDiagnosticsApp extends StatelessWidget {
  const CreativeColorDiagnosticsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AiDA | AI Diagnostics',
      theme: creativeColorTheme,
      home: const CreativeColorDiagnosticScreen(),
    );
  }
}

// ----------------------------------------------------------------------
// The Diagnostics Screen
// ----------------------------------------------------------------------

class CreativeColorDiagnosticScreen extends StatefulWidget {
  const CreativeColorDiagnosticScreen({super.key});

  @override
  State<CreativeColorDiagnosticScreen> createState() =>
      _CreativeColorDiagnosticScreenState();
}

class _CreativeColorDiagnosticScreenState
    extends State<CreativeColorDiagnosticScreen> {
  List<AdvancedDiagnosticData> _allRecords = [];
  List<AdvancedDiagnosticData> _displayedRecords = [];

  Timer? _timer;
  int _selectedRefreshInterval = 10;
  final List<dynamic> _intervalOptions = [5, 10, 15, 30, 60, 'Custom'];

  bool _showSearchBar = false;
  String _searchQuery = "";

  bool _showResolved = false;

  List<CategoryModel> _allCategories = [];
  final Set<String> _selectedCategoryNames = {};

  @override
  void initState() {
    super.initState();
    _startFetching();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Starts the periodic fetch
  void _startFetching() {
    _timer?.cancel();
    _fetchRecords();

    // Refresh every _selectedRefreshInterval seconds
    _timer = Timer.periodic(
      Duration(seconds: _selectedRefreshInterval),
      (timer) => _fetchRecords(),
    );
  }

  /// Fetch from server (sample route)
  Future<void> _fetchRecords() async {
    if (!mounted) return;
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token');
    if (token == null) throw Exception('No token found');
    try {
      final response = await http.get(
        Uri.parse('$urlEndPoint/advanced_diagnostic/items/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as List<dynamic>;
        setState(() {
          _allRecords = _parseRecords(data);
          _aggregateAllCategories();
          _applyAllFilters(_searchQuery);
        });
      } else {
        _showError(
            "Server error: ${response.statusCode} - ${response.reasonPhrase}");
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
      _showError("Network error: Could not connect to server.");
    }
  }

  /// Parse the returned records from JSON
  List<AdvancedDiagnosticData> _parseRecords(List<dynamic> data) {
    return data.map((item) {
      final src = item["_source"] as Map<String, dynamic>? ?? {};

      final problem = src["problem"] as String? ?? "No problem specified";
      final itersJson = (src["iterations"] as List<dynamic>?) ?? [];
      final iterations = itersJson.map((iter) {
        final desc =
            (iter["description"] ?? iter["descriptions"])?.toString() ??
                "No description";
        final cmd =
            (iter["command"] ?? iter["commands"])?.toString() ?? "No command";
        return AnalysisIteration(description: desc, command: cmd);
      }).toList();

      final cfgJson =
          src["advanced_diagnostic_config"] as Map<String, dynamic>? ?? {};
      final config = AdvancedDiagnosticConfig(
        environment: cfgJson["environment"] ?? "unknown",
        project: cfgJson["project"] ?? "unknown",
        trackingId: cfgJson["tracking_id"] ?? "",
        hostname: cfgJson["hostname"] ?? "unknown",
        program: cfgJson["program"] ?? "unknown",
      );

      final timestamp = src["timestamp"] as String? ?? "";
      final fixDesc = src["final_fix_description"] as String?;

      final ackList = (src["acknowledgements"] as List<dynamic>?) ?? [];
      final acknowledgements = ackList.map((ack) {
        return Acknowledgement(
          user: ack["user"] ?? "unknown",
          timestamp: ack["timestamp"] ?? "",
        );
      }).toList();

      ResolutionStatus? resolutionStatus;
      final resJson = src["resolution_status"] as Map<String, dynamic>?;
      if (resJson != null) {
        final user = resJson["user"] ?? "";
        final ts = resJson["timestamp"] ?? "";
        if (user.isNotEmpty && ts.isNotEmpty) {
          resolutionStatus = ResolutionStatus(user: user, timestamp: ts);
        }
      }

      final bool complete = src["complete"] as bool? ?? false;

      CanceledProcess? canceled;
      final canceledJson = src["canceled_process"] as Map<String, dynamic>?;
      if (canceledJson != null) {
        final cUser = canceledJson["user"] as String? ?? "";
        final cTs = canceledJson["timestamp"] as String? ?? "";
        if (cUser.isNotEmpty && cTs.isNotEmpty) {
          canceled = CanceledProcess(user: cUser, timestamp: cTs);
        }
      }

      final catJson = src["categories"] as List<dynamic>? ?? [];
      final categories = catJson.map((c) => c.toString()).toList();

      final lastUpdated = src["lastUpdated"] as String?;

      return AdvancedDiagnosticData(
        iterations: iterations,
        originalProblem: problem,
        config: config,
        timestamp: timestamp,
        finalFixDescription: fixDesc,
        acknowledgements: acknowledgements,
        resolutionStatus: resolutionStatus,
        complete: complete,
        canceledProcess: canceled,
        categories: categories,
        lastUpdated: lastUpdated,
      );
    }).toList();
  }

  /// Aggregates categories for filter-chips
  void _aggregateAllCategories() {
    final Map<String, int> catCounts = {};
    for (var record in _allRecords) {
      for (var catName in record.categories) {
        catCounts[catName] = (catCounts[catName] ?? 0) + 1;
      }
    }
    final allCats = catCounts.entries
        .map((e) => CategoryModel(name: e.key, count: e.value))
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    _allCategories = allCats;
  }

  /// Show an error if needed
  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: SelectableText(message),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Retry',
          textColor: Colors.white,
          onPressed: _fetchRecords,
        ),
      ),
    );
  }

  /// Update refresh interval
  void _onIntervalChanged(dynamic newValue) async {
    if (!mounted) return;
    if (newValue == null) return;

    if (newValue is int) {
      setState(() {
        _selectedRefreshInterval = newValue;
      });
      _startFetching();
    } else if (newValue == 'Custom') {
      final customVal = await _showCustomIntervalDialog();
      if (!mounted) return;
      if (customVal != null) {
        final sec = int.tryParse(customVal);
        if (sec != null && sec > 0) {
          setState(() {
            _selectedRefreshInterval = sec;
          });
          _startFetching();
        }
      }
    }
  }

  /// Dialog for custom refresh interval
  Future<String?> _showCustomIntervalDialog() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Custom Refresh Interval"),
          content: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Seconds'),
          ),
          actions: [
            TextButton(
              child: const Text("Cancel"),
              onPressed: () => Navigator.of(dialogContext).pop(null),
            ),
            TextButton(
              child: const Text("OK"),
              onPressed: () =>
                  Navigator.of(dialogContext).pop(ctrl.text.trim()),
            ),
          ],
        );
      },
    );
  }

  /// Search bar toggle
  void _toggleSearchBar() {
    setState(() {
      _showSearchBar = !_showSearchBar;
      if (!_showSearchBar) {
        _searchQuery = "";
        _applyAllFilters(_searchQuery);
      }
    });
  }

  void monitoringPage() {
    navigatorKey.currentState?.pushReplacementNamed('/status');
  }

  /// Toggle show resolved
  void _toggleResolved() {
    setState(() {
      _showResolved = !_showResolved;
      _applyAllFilters(_searchQuery);
    });
  }

  /// Apply search, resolved/unresolved, and category filters
  void _applyAllFilters(String query) {
    List<AdvancedDiagnosticData> temp;

    // 1) Search
    if (query.trim().isEmpty) {
      temp = List.from(_allRecords);
    } else {
      final lower = query.toLowerCase();
      temp = _allRecords.where((r) {
        final host = r.config.hostname.toLowerCase();
        final prog = r.config.program.toLowerCase();
        final prob = r.originalProblem.toLowerCase();
        final root = r.rootCause.toLowerCase();
        return host.contains(lower) ||
            prog.contains(lower) ||
            prob.contains(lower) ||
            root.contains(lower);
      }).toList();
    }

    // 2) Resolved / Unresolved
    if (_showResolved) {
      temp = temp.where((r) => r.isResolved).toList();
    } else {
      temp = temp.where((r) => !r.isResolved).toList();
    }

    // 3) Category
    if (_selectedCategoryNames.isNotEmpty) {
      temp = temp.where((r) {
        final setCats = r.categories.toSet();
        return setCats.intersection(_selectedCategoryNames).isNotEmpty;
      }).toList();
    }

    setState(() {
      _displayedRecords = temp;
    });
  }

  void _onSearchTextChanged(String val) {
    _searchQuery = val;
    _applyAllFilters(val);
  }

  /// Category selection
  void _onCategorySelected(String name, bool selected) {
    setState(() {
      if (selected) {
        _selectedCategoryNames.add(name);
      } else {
        _selectedCategoryNames.remove(name);
      }
      _applyAllFilters(_searchQuery);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const AnimatedSpaceBackground(),
          const SatelliteOverlay(),
          Column(
            children: [
              AppBar(
                backgroundColor: Colors.black54,
                title: _showSearchBar
                    ? TextField(
                        autofocus: true,
                        onChanged: _onSearchTextChanged,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: 'Search...',
                          hintStyle: TextStyle(color: Colors.white70),
                          border: InputBorder.none,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const GradientLogo(),
                          const SizedBox(width: 8),
                          Column(
                            children: [
                              Text(
                                'AI Diagnostics',
                                style: GoogleFonts.sora(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                              // ShaderMask(
                              //     blendMode: BlendMode.srcIn,
                              //     shaderCallback: (Rect bounds) {
                              //       return gradientForText.createShader(bounds);
                              //     },
                              //     child: ),
                            ],
                          ),
                        ],
                      ),
                centerTitle: true,
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    Navigator.of(context, rootNavigator: true).pop();
                  },
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.home),
                    onPressed: () => {
                      navigatorKey.currentState
                          ?.pushNamedAndRemoveUntil('/navigation', (_) => false)
                    },
                  ),
                  IconButton(
                    icon: Icon(_showSearchBar ? Icons.close : Icons.search),
                    onPressed: _toggleSearchBar,
                  ),
                  IconButton(
                    icon: Icon(
                      _showResolved ? Icons.check_circle : Icons.visibility_off,
                    ),
                    tooltip:
                        _showResolved ? 'Show Unresolved' : 'Show Resolved',
                    onPressed: _toggleResolved,
                  ),
                ],
              ),
              _buildCategoryFilterChips(),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: _buildIntervalSelector(),
              ),
              Expanded(
                child: _displayedRecords.isEmpty
                    ? _buildEmptyPlaceholder()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: _displayedRecords.length,
                        itemBuilder: (ctx, i) {
                          final record = _displayedRecords[i];
                          return _buildRecordCard(record);
                        },
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryFilterChips() {
    if (_allCategories.isEmpty) return const SizedBox();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _allCategories.map((cat) {
            final isSelected = _selectedCategoryNames.contains(cat.name);
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text("${cat.name} (${cat.count})"),
                selected: isSelected,
                onSelected: (val) => _onCategorySelected(cat.name, val),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildIntervalSelector() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Refresh Interval: ',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        DropdownButtonHideUnderline(
          child: DropdownButton<dynamic>(
            value: _intervalOptions.contains(_selectedRefreshInterval)
                ? _selectedRefreshInterval
                : 'Custom',
            items: _intervalOptions.map((opt) {
              if (opt is int) {
                return DropdownMenuItem<int>(
                  value: opt,
                  child: Text('$opt s'),
                );
              } else {
                return const DropdownMenuItem<String>(
                  value: 'Custom',
                  child: Text('Custom'),
                );
              }
            }).toList(),
            onChanged: _onIntervalChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyPlaceholder() {
    return Center(
      child: Text(
        _showResolved
            ? "No resolved diagnostics found."
            : "No unresolved diagnostics found.",
        style: const TextStyle(fontSize: 18, color: Colors.white70),
      ),
    );
  }

  Widget _buildRecordCard(AdvancedDiagnosticData data) {
    return Card(
      color: Colors.white.withOpacity(0.08),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: _buildLeadingIcon(data),
        title: _buildRecordTitle(data),
        subtitle: _buildRecordSubtitle(data),
        onTap: () => _showRecordDetailsBottomSheet(data),
      ),
    );
  }

  Widget _buildLeadingIcon(AdvancedDiagnosticData data) {
    if (data.canceledProcess != null) {
      return const Icon(Icons.cancel, color: Colors.red);
    } else if (data.isResolved || data.complete) {
      return const Icon(Icons.check_circle, color: Colors.green);
    } else {
      return const SpinningSyncIcon();
    }
  }

  Widget _buildRecordTitle(AdvancedDiagnosticData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.computer, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                "Host: ${data.config.hostname}",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.precision_manufacturing, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text("Program: ${data.config.program}"),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRecordSubtitle(AdvancedDiagnosticData data) {
    // Build short ack summary
    String ackSubtitle = "No acknowledgements yet";
    if (data.acknowledgements.isNotEmpty) {
      final lastAck = data.acknowledgements.last;
      final dt = DateTime.tryParse(lastAck.timestamp);
      if (dt != null) {
        final local = dt.toLocal();
        final localStr = DateFormat("yyyy-MM-dd HH:mm:ss").format(local);
        ackSubtitle = "Last ack by ${lastAck.user} on $localStr";
        if (data.acknowledgements.length > 1) {
          ackSubtitle += " (+${data.acknowledgements.length - 1} more)";
        }
      } else {
        ackSubtitle = "Last acknowledged by ${lastAck.user} (invalid time)";
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.dashboard, size: 18),
            const SizedBox(width: 6),
            Text(
              "${data.config.environment.toUpperCase()} - ${data.config.project}",
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.timeline, size: 18),
            const SizedBox(width: 6),
            Text(
              "Stage Count: ${data.iterations.length}",
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.person_outline, size: 16),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                ackSubtitle,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _buildStatusRow(data),
      ],
    );
  }

  Widget _buildStatusRow(AdvancedDiagnosticData data) {
    String status;
    Color color;
    IconData icon;

    if (data.canceledProcess != null) {
      status = "Canceled by ${data.canceledProcess!.user}";
      color = Colors.redAccent;
      icon = Icons.cancel;
    } else if (data.isResolved) {
      status = "Resolved by ${data.resolutionStatus!.user}";
      color = Colors.greenAccent;
      icon = Icons.verified_user;
    } else {
      status = "Unresolved";
      color = Colors.orangeAccent;
      icon = Icons.info_outline;
    }

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          status,
          style: TextStyle(
            color: color,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// Show details in a Bottom Sheet
  void _showRecordDetailsBottomSheet(AdvancedDiagnosticData data) {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black.withOpacity(0.5),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.90,
          minChildSize: 0.50,
          maxChildSize: 0.95,
          shouldCloseOnMinExtent: true,
          expand: false,
          builder: (context, scrollController) {
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Container(
                    width: 60,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade700,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),

                // Original Problem
                _buildColoredSection(
                  title: "Original Problem",
                  color: Colors.redAccent,
                  textColor: Colors.white,
                  icon: Icons.warning_amber_outlined,
                  child: SelectableText(data.originalProblem),
                ),

                // Analysis Iterations
                _buildColoredSection(
                  title: "Analysis Iterations",
                  color: Colors.orange,
                  textColor: Colors.black,
                  icon: Icons.sync,
                  child: _buildIterationsList(data.iterations),
                ),

                // Root Cause
                _buildColoredSection(
                  title: "Root Cause",
                  color: Colors.deepPurpleAccent,
                  textColor: Colors.white,
                  icon: Icons.priority_high,
                  child: SelectableText(
                    data.rootCause,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),

                // Metadata
                _buildColoredSection(
                  title: "Metadata",
                  color: Colors.blue,
                  textColor: Colors.white,
                  icon: Icons.info_outline,
                  child: _buildMetadataSection(data),
                ),

                // Final fix
                if (data.finalFixDescription != null)
                  _buildColoredSection(
                    title: "Final Fix Description",
                    color: Colors.greenAccent,
                    textColor: Colors.black,
                    icon: Icons.build_circle_outlined,
                    child: SelectableText(
                      data.finalFixDescription!,
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),

                // Resolution
                if (data.resolutionStatus != null)
                  _buildColoredSection(
                    title: "Resolution Status",
                    color: Colors.green,
                    textColor: Colors.white,
                    icon: Icons.verified_user,
                    child: _buildResolutionStatus(data.resolutionStatus!),
                  ),

                // Canceled
                if (data.canceledProcess != null)
                  _buildColoredSection(
                    title: "Canceled Process",
                    color: Colors.red,
                    textColor: Colors.white,
                    icon: Icons.cancel,
                    child: _buildCanceledProcess(data.canceledProcess!),
                  ),

                // Acknowledgements
                if (data.acknowledgements.isNotEmpty)
                  _buildColoredSection(
                    title: "Acknowledgements",
                    color: Colors.blueGrey,
                    textColor: Colors.white,
                    icon: Icons.people_alt_rounded,
                    child: _buildAcknowledgements(data.acknowledgements),
                  ),

                // Categories
                if (data.categories.isNotEmpty)
                  _buildColoredSection(
                    title: "Categories",
                    color: Colors.brown,
                    textColor: Colors.white,
                    icon: Icons.label,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: data.categories
                          .map(
                            (cat) => Chip(
                              label: Text(cat),
                              backgroundColor: Colors.white.withOpacity(0.2),
                            ),
                          )
                          .toList(),
                    ),
                  ),

                // Action Buttons (if not resolved)
                if (!data.isResolved) _buildActionButtons(data),
              ],
            );
          },
        );
      },
    );
  }

  /// Color-coded Section
  Widget _buildColoredSection({
    required String title,
    required Color color,
    required Color textColor,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle(
        style: TextStyle(color: textColor, fontSize: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: textColor),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: textColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildIterationsList(List<AnalysisIteration> iterations) {
    if (iterations.isEmpty) {
      return const Text("No iterations recorded.");
    }
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: iterations.length,
      itemBuilder: (ctx, i) {
        final iter = iterations[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Text(
              "Step ${i + 1}",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            title: SelectableText(iter.description),
            subtitle: Text(
              "Command: ${iter.command}",
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMetadataSection(AdvancedDiagnosticData data) {
    final cfg = data.config;
    String lastUpd = "N/A";
    if (data.lastUpdated != null && data.lastUpdated!.isNotEmpty) {
      final dt = DateTime.tryParse(data.lastUpdated!);
      if (dt != null) {
        final local = dt.toLocal();
        lastUpd = DateFormat("yyyy-MM-dd HH:mm:ss").format(local);
      } else {
        lastUpd = "Invalid: ${data.lastUpdated}";
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetaRowWithIcon(
          icon: Icons.cloud,
          label: "Environment",
          value: cfg.environment,
        ),
        _buildMetaRowWithIcon(
          icon: Icons.precision_manufacturing,
          label: "Program",
          value: cfg.program,
        ),
        _buildMetaRowWithIcon(
          icon: Icons.computer,
          label: "Hostname",
          value: cfg.hostname,
        ),
        _buildMetaRowWithIcon(
          icon: Icons.account_tree_outlined,
          label: "Project",
          value: cfg.project,
        ),
        const SizedBox(height: 8),
        _buildMetaRowWithIcon(
          icon: Icons.track_changes,
          label: "Tracking ID",
          value: cfg.trackingId,
        ),
        _buildMetaRowWithIcon(
          icon: Icons.update,
          label: "Last Updated (Local)",
          value: lastUpd,
        ),
      ],
    );
  }

  Widget _buildMetaRowWithIcon({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
  }

  Widget _buildResolutionStatus(ResolutionStatus r) {
    final dt = DateTime.tryParse(r.timestamp);
    if (dt == null) {
      return Text("Invalid timestamp: ${r.timestamp}");
    }
    final local = dt.toLocal();
    final localStr = DateFormat("yyyy-MM-dd HH:mm:ss").format(local);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetaRowWithIcon(
          icon: Icons.person,
          label: "Resolved By",
          value: r.user,
        ),
        _buildMetaRowWithIcon(
          icon: Icons.access_time,
          label: "Resolved At",
          value: localStr,
        ),
      ],
    );
  }

  Widget _buildCanceledProcess(CanceledProcess c) {
    final dt = DateTime.tryParse(c.timestamp);
    if (dt == null) {
      return Text("Invalid timestamp: ${c.timestamp}");
    }
    final local = dt.toLocal();
    final localStr = DateFormat("yyyy-MM-dd HH:mm:ss").format(local);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildMetaRowWithIcon(
          icon: Icons.person,
          label: "Canceled By",
          value: c.user,
        ),
        _buildMetaRowWithIcon(
          icon: Icons.access_time,
          label: "Canceled At",
          value: localStr,
        ),
      ],
    );
  }

  Widget _buildAcknowledgements(List<Acknowledgement> acks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: acks.map((ack) {
        final dt = DateTime.tryParse(ack.timestamp);
        String localStr;
        if (dt == null) {
          localStr = "Invalid timestamp: ${ack.timestamp}";
        } else {
          localStr = DateFormat("yyyy-MM-dd HH:mm:ss").format(dt.toLocal());
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text("${ack.user} acknowledged at $localStr"),
        );
      }).toList(),
    );
  }

  /// Action buttons: Acknowledge, Resolve, Cancel
  Widget _buildActionButtons(AdvancedDiagnosticData data) {
    final showCancel =
        data.canceledProcess == null && !data.complete && !data.isResolved;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          Expanded(
            child: _buildGradientButton(
              label: "Acknowledge",
              icon: Icons.thumb_up,
              colors: const [Colors.orangeAccent, Colors.deepOrange],
              onTap: () => _acknowledgeItem(data),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildGradientButton(
              label: "Resolve Issue",
              icon: Icons.check,
              colors: const [Colors.greenAccent, Colors.green],
              onTap: () => _confirmResolve(data),
            ),
          ),
          if (showCancel) ...[
            const SizedBox(width: 8),
            Expanded(
              child: _buildGradientButton(
                label: "Cancel",
                icon: Icons.cancel,
                colors: const [Colors.redAccent, Colors.red],
                onTap: () => _confirmCancel(data),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGradientButton({
    required String label,
    required IconData icon,
    required List<Color> colors,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: colors),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, color: Colors.white),
        label: Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  // Acknowledge
  Future<void> _acknowledgeItem(AdvancedDiagnosticData record) async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      final res = await http.post(
        Uri.parse("$urlEndPoint/advanced_diagnostic/acknowledge_item/"),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({"tracking_id": record.config.trackingId}),
      );
      if (res.statusCode == 200) {
        await _fetchRecords(); // Refresh
      } else {
        _showError("Failed to acknowledge: ${res.reasonPhrase}");
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
      _showError("Network error while acknowledging");
    }
  }

  // Confirm Resolve
  Future<void> _confirmResolve(AdvancedDiagnosticData record) async {
    final shouldResolve = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Confirm Resolution"),
          content: const Text("Are you sure you want to resolve this record?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text("Resolve"),
            ),
          ],
        );
      },
    );
    if (shouldResolve == true) {
      _resolveItem(record);
    }
  }

  // Perform the resolve
  Future<void> _resolveItem(AdvancedDiagnosticData record) async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      final res = await http.post(
        Uri.parse("$urlEndPoint/advanced_diagnostic/resolve_item/"),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({"tracking_id": record.config.trackingId}),
      );
      if (res.statusCode == 200) {
        await _fetchRecords();
        Navigator.of(context).maybePop(); // close bottom sheet if open
      } else {
        _showError("Resolve error: ${res.body}");
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
      _showError("Network error while resolving item");
    }
  }

  // Confirm Cancel
  Future<void> _confirmCancel(AdvancedDiagnosticData record) async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Confirm Cancel"),
          content:
              const Text("Are you sure you want to cancel this diagnostic?"),
          actions: [
            TextButton(
              child: const Text("No"),
              onPressed: () => Navigator.of(dialogContext).pop(false),
            ),
            TextButton(
              child: const Text("Yes, Cancel"),
              onPressed: () => Navigator.of(dialogContext).pop(true),
            ),
          ],
        );
      },
    );
    if (shouldCancel == true) {
      _cancelItem(record);
    }
  }

  // Perform cancel
  Future<void> _cancelItem(AdvancedDiagnosticData record) async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');

      final res = await http.post(
        Uri.parse("$urlEndPoint/advanced_diagnostic/cancel_diagnostic_item/"),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({"tracking_id": record.config.trackingId}),
      );
      if (res.statusCode == 200) {
        await _fetchRecords();
        Navigator.of(context).maybePop(); // close bottom sheet if open
      } else {
        _showError("Cancel error: ${res.reasonPhrase}");

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
      _showError("Network error while canceling item");
    }
  }
}

// ----------------------------------------------------------------------
// A spinning icon for unresolved items
// ----------------------------------------------------------------------
class SpinningSyncIcon extends StatefulWidget {
  const SpinningSyncIcon({super.key});

  @override
  State<SpinningSyncIcon> createState() => _SpinningSyncIconState();
}

class _SpinningSyncIconState extends State<SpinningSyncIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _spin,
      child: const Icon(Icons.sync, color: Colors.orange),
    );
  }
}
