import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:advanced_ai_diagnostics/ui_elements.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart'; // for listEquals
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:timeago/timeago.dart' as timeago;

import 'action_dialog.dart';
import 'aggregate_dashboard_page.dart';
import 'main.dart';
import 'scale_recommendation_dialog.dart';

/// Represents a single monitoring record with raw and parsed task details
var myUser = "";

class FailingStateRecord {
  final String service;
  final String metric;
  final String description;
  final bool result;
  final String detail;
  final DateTime timestamp;

  FailingStateRecord({
    required this.service,
    required this.metric,
    required this.description,
    required this.result,
    required this.detail,
    required this.timestamp,
  });
}

/// Represents a single monitoring record with raw and parsed task details
class Record {
  // ── raw top-level metadata ─────────────────────────────────
  final String name;
  final String ip;
  final String launchtime;
  final String instancetype;
  final String instanceId;
  final String program;

  // ── timestamps & tag-style metadata ────────────────────────
  final List<String> timestamp;
  final Map<String, dynamic> tags;

  // ── stats block (one per polling cycle, newest first) ─────
  final List<Map<String, dynamic>> stats;

  // ── raw tasks, normalized to List<List<Map>> ─────────────
  final List<List<Map<String, dynamic>>> tasks;

  // ── parsed helper collections from tasks ──────────────────
  final List<PartitionInfo> partitions;
  final List<RamInfo> rams;
  final List<MongoCheck> checks;

  // ── failing-states list with timestamps ─────────────────
  final List<FailingStateRecord> failingStateRecords;

  // ── RabbitMQ “high queues” (if any) ───────────────────────
  final List<RabbitQueueInfo> rabbitQueues;

  // ── CloudWatch metrics (metricName ➜ datapoints) ─────────
  final Map<String, List<CloudwatchPoint>> cloudwatch;

  // ── currently active issues (service::metric) ─────────────

  Record({
    required this.name,
    required this.ip,
    required this.instancetype,
    required this.instanceId,
    required this.program,
    required this.timestamp,
    required this.tags,
    required this.stats,
    required this.tasks,
    required this.partitions,
    required this.rams,
    required this.checks,
    required this.failingStateRecords,
    required this.rabbitQueues,
    required this.cloudwatch,
    required this.launchtime,
  });

  factory Record.fromJson(Map<String, dynamic> json) {
    // 1) tasks → List<List<Map>>
    final rawTasks = json['tasks'] as List;
    final tasks = rawTasks.map<List<Map<String, dynamic>>>((list) {
      if (list is List) return List<Map<String, dynamic>>.from(list);
      if (list is Map<String, dynamic>) {
        return [Map<String, dynamic>.from(list)];
      }
      return <Map<String, dynamic>>[];
    }).toList();

    // 2) parse partitions, RAM, Mongo checks
    final parts = <PartitionInfo>[];
    final rams = <RamInfo>[];
    final checks = <MongoCheck>[];
    for (final batch in tasks) {
      for (final t in batch) {
        if (t['disk'] != null) {
          for (final p in t['disk'] as List) {
            parts.add(PartitionInfo.fromJson(p as Map<String, dynamic>));
          }
        }
        if (t['ram'] != null) {
          rams.add(RamInfo.fromJson(t['ram'] as Map<String, dynamic>));
        }
        if (t['mongodb'] != null) {
          final m = Map<String, dynamic>.from(t['mongodb']);
          const required = [
            'role',
            'connection',
            'connections',
            'long_running_operations',
            'replication_lag',
            'replication_lag_ms',
          ];
          if (required.every(m.containsKey)) {
            final role = (m['role'] as String?)?.toLowerCase();
            if (role != 'mongos' && role != 'router') {
              checks.add(MongoCheck.fromJson(m));
            }
          }
        }
      }
    }

    // 3) parse failing-states entries with their own timestamps
    final failingRecs = <FailingStateRecord>[];
    final rawFail = json['failing_states'] as List<dynamic>?;

    if (rawFail != null) {
      for (final entryRaw in rawFail) {
        final entry = entryRaw as Map<String, dynamic>;

        // Grab and validate the timestamp
        final tsString = entry['timestamp'] as String?;
        if (tsString == null) continue;
        final parsed = DateTime.tryParse(tsString);
        if (parsed == null) continue;
        final ts = parsed.toLocal();

        // Iterate over each service→metric map (skip the 'timestamp' key)
        entry.forEach((key, val) {
          if (key == 'timestamp') return;
          final svc = key;
          final metrics = val as Map<String, dynamic>;

          metrics.forEach((metric, dataRaw) {
            final data = dataRaw as Map<String, dynamic>;
            failingRecs.add(FailingStateRecord(
              service: svc,
              metric: metric,
              description: data['description']?.toString() ?? '',
              result: data['result'] as bool,
              detail: data['detail'].toString(),
              timestamp: ts,
            ));
          });
        });
      }

      // Sort newest first
      failingRecs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    }

    // 4) RabbitMQ queues
    final rabbitQueues = <RabbitQueueInfo>[];
    final rawRb = json['rabbitmq'] as Map<String, dynamic>?;
    if (rawRb != null && rawRb['is_high_queues'] == true) {
      for (final entry in rawRb['high_queues'] as List<dynamic>) {
        rabbitQueues.add(RabbitQueueInfo.fromJson(entry));
      }
    }

    // 5) CloudWatch metrics
    final cw = <String, List<CloudwatchPoint>>{};
    final rawCW = json['cloudwatch'] as Map<String, dynamic>?;
    if (rawCW != null) {
      rawCW.forEach((metric, list) {
        cw[metric] = (list as List)
            .map((e) => CloudwatchPoint.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.ts.compareTo(b.ts));
      });
    }

    return Record(
      name: json['name'] as String,
      ip: json['ip'] as String,
      instancetype: json['InstanceType'] as String,
      instanceId: json['InstanceId'] as String,
      program: json['Program'] as String,
      timestamp: List<String>.from(json['timestamp'] as List),
      tags: Map<String, dynamic>.from(json['Tags'] as Map),
      stats: List<Map<String, dynamic>>.from(json['stats'] as List),
      tasks: tasks,
      partitions: parts,
      rams: rams,
      checks: checks,
      failingStateRecords: failingRecs,
      rabbitQueues: rabbitQueues,
      cloudwatch: cw,
      launchtime: json['LaunchTime'] ?? '',
    );
  }

  /// Most recent stats map (newest first)
  Map<String, dynamic> get statsMap => stats.first;

  /// Every numeric key in [statsMap]
  Set<String> get numericMetricKeys => statsMap.keys.toSet();

  /// Convenient accessor for a single numeric stat
  double? metricValue(String metricName) {
    final v = statsMap[metricName];
    return v is num ? v.toDouble() : null;
  }
}

class _FailingStatesWidget extends StatefulWidget {
  final List<FailingStateRecord> failingStateRecords;

  final DateTime lastUpdate;

  const _FailingStatesWidget({
    required this.failingStateRecords,
    required this.lastUpdate,
  });

  @override
  State<_FailingStatesWidget> createState() => _FailingStatesWidgetState();
}

class _FailingStatesWidgetState extends State<_FailingStatesWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  bool _showHistory = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 1) Filter only the records whose result == true

    final mostRecentFail = widget.failingStateRecords.isEmpty
        ? null
        : widget.failingStateRecords.first;

    final hasAlert = mostRecentFail != null &&
        (mostRecentFail.timestamp.isAfter(widget.lastUpdate) ||
            mostRecentFail.timestamp.isAtSameMomentAs(widget.lastUpdate));

    final activeRecs =
        widget.failingStateRecords.where((r) => r.result).toList();
    // 2) Full history
    final historyRecs = widget.failingStateRecords;

    // 3) Pick out the newest active alert, if any
    final FailingStateRecord? newest =
        activeRecs.isNotEmpty ? activeRecs.first : null;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121220).withOpacity(0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasAlert
              ? Colors.redAccent.withOpacity(0.5)
              : Colors.greenAccent.withOpacity(0.5),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: hasAlert
                ? Colors.redAccent.withOpacity(0.2)
                : Colors.greenAccent.withOpacity(0.2),
            blurRadius: 20,
            spreadRadius: 1,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- Banner only if there's a currently active alert ---
          if (newest != null) ...[
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                hasAlert
                    ? const Icon(Icons.warning_amber_rounded,
                        color: Colors.orange, size: 20)
                    : const Icon(Icons.check_box_rounded,
                        color: Colors.green, size: 20),
                Text(
                  hasAlert
                      ? 'ACTIVE ISSUE: '
                      : 'ISSUE RESOLVED: '
                          '${newest.service.toUpperCase()} – ${newest.metric}',
                  style: TextStyle(
                    color: hasAlert ? Colors.redAccent : Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  timeago.format(newest.timestamp),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildStateCard(newest, failing: hasAlert),
          ],

          // --- Always show history toggle if there are any records ---
          if (historyRecs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Divider(color: Colors.white.withOpacity(0.2)),
            GestureDetector(
              onTap: () => setState(() => _showHistory = !_showHistory),
              child: Row(
                children: [
                  Icon(
                    _showHistory ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${historyRecs.length} Alert${historyRecs.length > 1 ? 's' : ''}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
            if (_showHistory)
              Column(
                children: historyRecs.map((rec) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${rec.service} • ${rec.metric} • ${timeago.format(rec.timestamp)}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                        _buildStateCard(rec, compact: true, failing: hasAlert),
                      ],
                    ),
                  );
                }).toList(),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildStateCard(FailingStateRecord rec,
      {bool failing = true, bool compact = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: failing
            ? Colors.red.withOpacity(0.05)
            : Colors.green.withOpacity(0.05),
        border: Border.all(
          color: failing
              ? Colors.redAccent.withOpacity(0.3)
              : Colors.greenAccent.withOpacity(0.3),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact)
            AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: failing
                        ? Colors.redAccent.withOpacity(_pulseController.value)
                        : Colors.greenAccent
                            .withOpacity(_pulseController.value),
                    boxShadow: [
                      BoxShadow(
                        color: failing
                            ? Colors.redAccent
                                .withOpacity(_pulseController.value)
                            : Colors.greenAccent
                                .withOpacity(_pulseController.value),
                        blurRadius: 6,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                );
              },
            ),
          if (!compact) const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rec.description,
                  style: TextStyle(
                    color: failing ? Colors.redAccent : Colors.greenAccent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Tooltip(
                  message: rec.detail,
                  waitDuration: const Duration(milliseconds: 300),
                  child: GestureDetector(
                    onTap: () {
                      showGlassMorphicDialog(
                        context: context,
                        message: rec.detail,
                        type: DialogType.error,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: failing
                            ? Colors.redAccent.withOpacity(0.25)
                            : Colors.greenAccent.withOpacity(0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        rec.detail.length > 50
                            ? '⚠ Tap to read more'
                            : rec.detail,
                        style: TextStyle(
                          color:
                              failing ? Colors.redAccent : Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'RobotoMono',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SharedWith {
  final Map name;
  final String user;
  final DateTime timestamp;
  final bool viewed;

  SharedWith.fromJson(Map<String, dynamic> json)
      : name = json['name'],
        user = json['user'],
        timestamp = DateTime.parse(json['timestamp'] as String).toLocal(),
        viewed = json['viewed'] as bool;
}

/// Models a notification

class NotificationItem {
  final String id;
  final String title;
  final String body;
  final List<SharedWith> sharedWith;
  final DateTime timestamp;

  NotificationItem({
    required this.id,
    required this.title,
    required this.body,
    required this.sharedWith,
    required this.timestamp,
  });

  /// Builds from raw JSON: uses [index] as its id,
  /// and picks the timestamp entry for [currentUser].
  factory NotificationItem.fromJson(
    Map<String, dynamic> json,
    int index,
    String currentUser,
  ) {
    final swList = (json['shared_with'] as List)
        .map((e) => SharedWith.fromJson(e as Map<String, dynamic>))
        .toList();

    // find the currentUser’s entry (or fall back to the first one)
    final matched = swList.firstWhere(
      (s) => s.name['last'] == currentUser,
      orElse: () => swList.first,
    );

    return NotificationItem(
      id: json['_id'].toString(),
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      sharedWith: swList,
      timestamp: matched.timestamp,
    );
  }

  bool isViewedBy(String user) =>
      sharedWith.any((s) => s.name['last'] == user && s.viewed);
}

class RabbitQueueInfo {
  final String name;
  final int timeToCompleteMs;

  RabbitQueueInfo.fromJson(Map<String, dynamic> json)
      : name = json['name'] as String,
        timeToCompleteMs = json['time_to_complete_ms'] as int;
}

class SharedWithAvatars extends StatelessWidget {
  final List<SharedWith> sharedWith;

  const SharedWithAvatars({super.key, required this.sharedWith});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      children: sharedWith.map((sw) {
        final initials = sw.name['first'][0] + sw.name['last'][0];

        // Use sw.timestamp directly (it's already a DateTime), and format it with timeago:
        final ago = timeago.format(sw.timestamp);

        return Tooltip(
          message: '${sw.name['first']} ${sw.name['last']}\n'
              '${sw.viewed ? "Read" : "Unread"}\n'
              '$ago',
          child: CircleAvatar(
            radius: 12,
            backgroundColor:
                sw.viewed ? Colors.grey.shade600 : Colors.tealAccent,
            child: Text(
              initials,
              style: const TextStyle(fontSize: 10, color: Colors.black87),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class SideNavWithIssues extends StatelessWidget {
  final List<String> programs;
  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onShowNotifications;
  final int unreadCount;
  final Map<String, int> issueCounts;
  final VoidCallback onShowAggregate;

  const SideNavWithIssues({
    super.key,
    required this.programs,
    required this.selected,
    required this.onSelect,
    required this.onRefresh,
    required this.onShowNotifications,
    required this.onShowAggregate,
    required this.unreadCount,
    required this.issueCounts,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF091E3E), Color(0xFF001021)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 12,
            offset: Offset(3, 0),
          )
        ],
      ),
      child: SafeArea(
        child: Column(
          children: [
            _buildLogo(),
            const SizedBox(height: 16),
            _buildIconButtons(context),
            const Divider(color: Colors.white12),
            Expanded(child: _buildProgramList(context)),
            const Divider(color: Colors.white12),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Icon(Icons.analytics, color: Colors.cyanAccent, size: 28),
          SizedBox(width: 8),
          Text(
            'AiDA',
            style: TextStyle(
              color: Colors.cyanAccent,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIconButtons(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceEvenly,
      spacing: 12, // horizontal gap between buttons
      runSpacing: 8, // vertical gap when they wrap
      children: [
        _actionButton(Icons.home, 'Home', () {
          navigatorKey.currentState
              ?.pushNamedAndRemoveUntil('/navigation', (_) => false);
        }),
        _actionButton(Icons.dashboard_customize, 'Summary', onShowAggregate),
        _actionButton(Icons.memory, 'AI Diagnostics', () {
          navigatorKey.currentState?.pushNamed('/diagnostics');
        }),
        _actionButton(Icons.speed_outlined, 'Scale Recommendations', () {
          navigatorKey.currentState?.pushNamed('/scale-recommendations');
        }),
        Stack(
          clipBehavior: Clip.none,
          children: [
            _actionButton(Icons.notifications, 'Alerts', onShowNotifications),
            if (unreadCount > 0)
              Positioned(
                right: 0,
                top: 0,
                child: _badge(unreadCount, Colors.redAccent),
              ),
          ],
        ),
        _actionButton(Icons.refresh, 'Refresh', onRefresh),
      ],
    );
  }

  Widget _actionButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, color: Colors.white70, size: 24),
          ),
        ),
      ),
    );
  }

  Widget _buildProgramList(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: programs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (ctx, i) {
        final prog = programs[i];
        final isSelected = prog == selected;
        final issues = issueCounts[prog] ?? 0;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.cyanAccent.withOpacity(0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.cyanAccent.withOpacity(0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ]
                : [],
          ),
          child: ListTile(
            dense: true,
            leading: Icon(
              Icons.memory,
              color: isSelected ? Colors.cyanAccent : Colors.white70,
            ),
            title: Text(
              prog,
              style: TextStyle(
                color: isSelected ? Colors.cyanAccent : Colors.white70,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            trailing: issues > 0 ? _badge(issues, Colors.orangeAccent) : null,
            onTap: () => onSelect(prog),
          ),
        );
      },
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        '© ${DateTime.now().year} AiDA Diagnostics',
        style: const TextStyle(color: Colors.white30, fontSize: 12),
      ),
    );
  }

  Widget _badge(int n, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
                color: c.withOpacity(0.6),
                blurRadius: 4,
                offset: const Offset(0, 1))
          ],
        ),
        child: Text(
          '$n',
          style: const TextStyle(color: Colors.white, fontSize: 10),
          textAlign: TextAlign.center,
        ),
      );
}

class NotificationsMenu extends StatefulWidget {
  final List<NotificationItem> notifications;
  final void Function(NotificationItem) onViewed;

  const NotificationsMenu({
    required this.notifications,
    required this.onViewed,
    super.key,
  });

  @override
  State<NotificationsMenu> createState() => _NotificationsMenuState();
}

class _NotificationsMenuState extends State<NotificationsMenu> {
  List<_DisplayNotification> ec2Items = [];
  Timer? pollingTimer;

  @override
  void initState() {
    super.initState();
    _fetchEC2Status();
    pollingTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _fetchEC2Status());
  }

  @override
  void dispose() {
    pollingTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchEC2Status() async {
    try {
      const storage = FlutterSecureStorage();
      final token = await storage.read(key: 'access_token');
      if (token == null) throw Exception('No token found');
      final response =
          await http.get(Uri.parse('$urlEndPoint/scaling/status/'), headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      });

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<_DisplayNotification> items = [];

        for (var status in data['status']) {
          items.add(_DisplayNotification(
            id: status['instance_id'],
            title: 'EC2 Scaling - ${status['instance_id']}',
            body: 'Status: ${status['status']}',
            timestamp: DateTime.parse(status['timestamp'] as String).toLocal(),
            isEC2: true,
            steps: status['steps'],
          ));
        }

        setState(() => ec2Items = items);
      }
    } catch (_) {
      print(_);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<_DisplayNotification> merged = [
      ...widget.notifications.map((n) => _DisplayNotification(
            id: n.id,
            title: n.title,
            body: n.body,
            timestamp: n.timestamp,
            sharedWith: n.sharedWith,
            original: n,
          )),
      ...ec2Items,
    ]..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return SafeArea(
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: Colors.black.withOpacity(0.6),
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  child: Row(
                    children: [
                      Icon(Icons.notifications, color: Colors.white, size: 24),
                      SizedBox(width: 8),
                      Text(
                        'Notifications',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: merged.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Colors.white12, height: 1),
                    itemBuilder: (context, index) {
                      final n = merged[index];

                      // EC2 scaling card
                      if (n.isEC2 && n.steps != null) {
                        final progress =
                            (n.steps!.last['percent_complete'] ?? 0) / 100;

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: Card(
                            color: Colors.white10,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.cloud_sync,
                                          color: Colors.tealAccent),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          n.title,
                                          style: const TextStyle(
                                              color: Colors.tealAccent,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16),
                                        ),
                                      ),
                                      Text(
                                        timeago.format(n.timestamp),
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  LinearProgressIndicator(
                                    value: progress,
                                    backgroundColor: Colors.white24,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                            Colors.tealAccent),
                                  ),
                                  const SizedBox(height: 12),
                                  ...n.steps!.map((step) {
                                    final done = step['status'] == 'completed';
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: Row(
                                        children: [
                                          Icon(
                                            done
                                                ? Icons.check_circle
                                                : Icons.timelapse,
                                            color: done
                                                ? Colors.tealAccent
                                                : Colors.white54,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              step['step'],
                                              style: TextStyle(
                                                color: done
                                                    ? Colors.tealAccent
                                                    : Colors.white70,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            '${step['percent_complete']}%',
                                            style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                ],
                              ),
                            ),
                          ),
                        );
                      }

                      // Regular notification
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        title: Text(
                          n.title,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              n.body,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70),
                            ),
                            if (n.sharedWith != null)
                              SharedWithAvatars(sharedWith: n.sharedWith!),
                          ],
                        ),
                        trailing: Text(
                          timeago.format(n.timestamp),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                        onTap: () {
                          if (n.original != null) {
                            _showDetailSheet(context, n.original!);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showDetailSheet(BuildContext context, NotificationItem n) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollCtrl) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Material(
              color: Colors.grey[900]?.withOpacity(0.95),
              child: SingleChildScrollView(
                controller: scrollCtrl,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      n.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      timeago.format(n.timestamp),
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      n.body,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 16, height: 1.4),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Shared With',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    SharedWithAvatars(sharedWith: n.sharedWith),
                    const SizedBox(height: 32),
                    Center(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.tealAccent,
                          foregroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24)),
                        ),
                        icon: const Icon(Icons.mark_email_read),
                        label: const Text('Acknowledge Alert'),
                        onPressed: () {
                          widget.onViewed(n);
                          Navigator.of(ctx).pop();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DisplayNotification {
  final String id;
  final String title;
  final String body;
  final DateTime timestamp;
  final List<SharedWith>? sharedWith;
  final List<dynamic>? steps;
  final bool isEC2;
  final NotificationItem? original;

  _DisplayNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.timestamp,
    this.sharedWith,
    this.steps,
    this.isEC2 = false,
    this.original,
  });
}

class LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const LegendDot({
    super.key,
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // the colored dot
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

class MonitoringStatus extends StatefulWidget {
  const MonitoringStatus({super.key});

  @override
  _MonitoringStatusState createState() => _MonitoringStatusState();
}

class _MonitoringStatusState extends State<MonitoringStatus>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  List<Record> _records = [];
  List<NotificationItem> _notifications = [];
  Timer? _timer;
  late final AnimationController _fadeCtrl;

  // current selections
  String _selectedEnvironment = '';
  String _selectedProject = '';
  String _selectedProgram = '';
  String? _selectedMetric;
  String _selectedTimeRange = '1h';

  final Map<String, Duration> _timeRangeOptions = {
    // '15m': const Duration(minutes: 15),
    '1h': const Duration(hours: 1),
    '6h': const Duration(hours: 6),
    '12h': const Duration(hours: 12),
    '1d': const Duration(days: 1),
    '3d': const Duration(days: 3),
    '7d': const Duration(days: 7),
    '30d': const Duration(days: 30),
  };

  DateTime get _timeFrom =>
      DateTime.now().subtract(_timeRangeOptions[_selectedTimeRange]!);

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

    _fetchDataWithTime();
    _fetchNotifications();

    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      _fetchDataWithTime(silent: true);
      _fetchNotifications(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchDataWithTime({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);
    final data = await _loadData(startTime: _timeFrom, endTime: DateTime.now());
    if (!mounted) return;
    setState(() {
      _records = data;
      _isLoading = false;
    });
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Updated for last $_selectedTimeRange'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<List<Record>> _loadData({
    DateTime? startTime,
    DateTime? endTime,
  }) async {
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token');
    if (token == null) throw Exception('No token');

    final params = {
      if (startTime != null) 'start': startTime.toUtc().toIso8601String(),
      if (endTime != null) 'end': endTime.toUtc().toIso8601String(),
    };
    final uri = Uri.parse('$urlEndPoint/cluster_status/')
        .replace(queryParameters: params);
    final resp = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode == 200) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      return json.entries
          .map((e) => Record.fromJson(e.value as Map<String, dynamic>))
          .toList();
    } else {
      await storage.delete(key: 'access_token');
      navigatorKey.currentState
          ?.pushNamedAndRemoveUntil('/login', (_) => false);
      throw Exception('Invalid token');
    }
  }

  Future<void> _fetchNotifications({bool silent = false}) async {
    final data = await _loadNotifications();
    if (!mounted) return;
    setState(() => _notifications = data);
  }

  Future<List<NotificationItem>> _loadNotifications() async {
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token');
    if (token == null) throw Exception('No token');

    final meResp = await http.get(
      Uri.parse('$urlEndPoint/me/'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (meResp.statusCode == 200) {
      final meJson = jsonDecode(meResp.body);
      myUser = meJson['sub'];
    }

    try {
      final resp = await http.get(Uri.parse('$urlEndPoint/notifications/'),
          headers: {
            'Authorization': 'Bearer $token'
          }).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List<dynamic>;
        return list
            .asMap()
            .entries
            .map((e) => NotificationItem.fromJson(
                  e.value as Map<String, dynamic>,
                  e.key,
                  myUser,
                ))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _markAsViewed(NotificationItem n) async {
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token');
    if (token == null) return;
    final uri = Uri.parse('$urlEndPoint/notifications/${n.id}/view/');
    final res = await http.post(uri,
        headers: {'Authorization': 'Bearer $token'},
        body: jsonEncode({'_id': n.id}));
    if (res.statusCode == 200) _fetchNotifications(silent: true);
  }

  void _showNotificationsMenu() {
    _fetchNotifications();
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Notifications',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, __, ___) => StatefulBuilder(
        builder: (ctx, setStateMenu) => Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: NotificationsMenu(
              notifications: _notifications,
              onViewed: (n) async {
                await _markAsViewed(n);
                setStateMenu(() {});
              },
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim1, anim2, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
            .animate(anim1),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = _records;
    final isWide = MediaQuery.of(context).size.width >= 960;

    // ─── build filter lists & defaults ─────────────────────────────
    final environments = all
        .map((r) => r.tags['Environment'] as String)
        .toSet()
        .toList()
      ..sort();
    if (_selectedEnvironment.isEmpty && environments.isNotEmpty) {
      _selectedEnvironment = environments.first;
    }

    final projects = all
        .where((r) => r.tags['Environment'] == _selectedEnvironment)
        .map((r) => r.tags['Project'] as String)
        .toSet()
        .toList()
      ..sort();
    if (_selectedProject.isEmpty && projects.isNotEmpty) {
      _selectedProject = projects.first;
    }

    final filteredByTag = all.where((r) {
      return r.tags['Environment'] == _selectedEnvironment &&
          r.tags['Project'] == _selectedProject;
    }).toList();

    final programNames = filteredByTag.map((r) => r.program).toSet().toList()
      ..sort();
    if (_selectedProgram.isEmpty && programNames.isNotEmpty) {
      _selectedProgram = programNames.first;
    }

    final issueCounts = <String, int>{};
    for (final prog in programNames) {
      issueCounts[prog] = filteredByTag.where((r) {
        // only look at this program
        if (r.program != prog) return false;

        // 1) most recent failing‐state, if any
        final latestFail = r.failingStateRecords.isNotEmpty
            ? r.failingStateRecords.first
            : null;
        if (latestFail == null || !latestFail.result) return false;

        // 2) compute the true last‐update time
        final lastUpdate = r.timestamp
            .map((s) => DateTime.tryParse(s)?.toLocal())
            .where((dt) => dt != null)
            .cast<DateTime>()
            .reduce((a, b) => a.isAfter(b) ? a : b);

        // 3) count only if that failure is at or after lastUpdate
        return latestFail.timestamp.compareTo(lastUpdate) >= 0;
      }).length;
    }

    // ─── side nav ────────────────────────────────────────────────────
    final sideNav = SideNavWithIssues(
      programs: programNames,
      selected: _selectedProgram,
      onSelect: (p) => setState(() => _selectedProgram = p),
      onRefresh: () => _fetchDataWithTime(),
      onShowNotifications: _showNotificationsMenu,
      onShowAggregate: () {
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => AggregateDashboardPage(allRecords: _records)));
      },
      unreadCount: _notifications
          .where((n) => n.sharedWith.any((s) => s.user == myUser && !s.viewed))
          .length,
      issueCounts: issueCounts,
    );

    final byProgram =
        filteredByTag.where((r) => r.program == _selectedProgram).toList();

    // ─── filter row ──────────────────────────────────────────────────
    final filterRow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        GlassDropdown<String>(
          label: 'Environment',
          icon: Icons.cloud,
          value: _selectedEnvironment,
          items: environments
              .map((env) => DropdownMenuItem(value: env, child: Text(env)))
              .toList(),
          onChanged: (env) {
            if (env == null) return;
            setState(() {
              _selectedEnvironment = env;
              final newProjects = all
                  .where((r) => r.tags['Environment'] == env)
                  .map((r) => r.tags['Project'] as String)
                  .toSet()
                  .toList()
                ..sort();
              _selectedProject =
                  newProjects.isNotEmpty ? newProjects.first : '';
              _selectedProgram = '';
            });
          },
        ),
        const SizedBox(width: 12),
        GlassDropdown<String>(
          label: 'Project',
          icon: Icons.folder,
          value: _selectedProject,
          items: projects
              .map((proj) => DropdownMenuItem(value: proj, child: Text(proj)))
              .toList(),
          onChanged: (proj) {
            if (proj == null) return;
            setState(() {
              _selectedProject = proj;
              _selectedProgram = '';
            });
          },
        ),
        const SizedBox(width: 12),
        GlassDropdown<String>(
          label: 'Time Range',
          icon: Icons.schedule,
          value: _selectedTimeRange,
          items: _timeRangeOptions.keys
              .map((k) => DropdownMenuItem(value: k, child: Text('Last $k')))
              .toList(),
          onChanged: (range) {
            if (range == null) return;
            setState(() => _selectedTimeRange = range);
            _fetchDataWithTime();
          },
        ),
      ]),
    );

    // ─── loading screen ─────────────────────────────────────────────
    final loading = Stack(
      key: const ValueKey('loading'),
      children: [
        const AnimatedSpaceBackground(),
        const SatelliteOverlay(),
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GradientLogo(),
                const SizedBox(height: 8),
                Text(
                  'Retrieving System Metrics',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.poppins(
                    fontSize: 36,
                    fontWeight: FontWeight.w600,
                    color: AidaColors.primaryText,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'AI-Powered Diagnostics & Performance Monitoring',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.lato(
                    fontSize: 18,
                    fontWeight: FontWeight.w400,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 32),
                const LogoLinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ],
    );

    // ─── main content ───────────────────────────────────────────────
    Widget contentBody = Column(
      children: [
        filterRow,
        Expanded(
          child: _ProgramView(
            records: byProgram,
            metric: _selectedMetric,
            onMetricChanged: (m) => setState(() => _selectedMetric = m),
          ),
        ),
      ],
    );

    final content = Stack(
      key: const ValueKey('content'),
      children: [
        Positioned.fill(
          child: Image.asset(
            'assets/background.jpg',
            fit: BoxFit.cover,
          ),
        ),
        // dark overlay
        Positioned.fill(
          child: Container(color: Colors.black.withOpacity(0.5)),
        ),
        // SpaceMonitorOverlay(
        //   records: _records
        //       .where((r) => r.failingStateRecords.any((fs) => fs.result))
        //       .toList(),
        // ),
        FadeTransition(
          opacity: _fadeCtrl,
          child: isWide
              ? Row(
                  children: [
                    sideNav,
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: contentBody),
                        ],
                      ),
                    ),
                  ],
                )
              : CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      title: const Text('Infrastructure Monitor'),
                      floating: true,
                      automaticallyImplyLeading: false,
                      backgroundColor: Colors.black.withOpacity(0.75),
                      leading: Builder(
                        builder: (ctx) => IconButton(
                          icon: const Icon(Icons.menu),
                          tooltip: 'Open menu',
                          onPressed: () => Scaffold.of(ctx).openDrawer(),
                        ),
                      ),
                      actions: [
                        IconButton(
                          tooltip: 'Notifications',
                          icon: const Icon(Icons.notifications),
                          onPressed: _showNotificationsMenu,
                        ),
                        IconButton(
                          tooltip: 'Refresh',
                          icon: const Icon(Icons.refresh),
                          onPressed: _fetchDataWithTime,
                        ),
                        IconButton(
                          tooltip: 'Aggregate',
                          icon: const Icon(Icons.dashboard_customize),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  AggregateDashboardPage(allRecords: _records),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SliverFillRemaining(child: contentBody),
                  ],
                ),
        ),
      ],
    );

    return Scaffold(
      drawer:
          (!isWide && filteredByTag.isNotEmpty) ? Drawer(child: sideNav) : null,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 800),
        switchInCurve: Curves.easeIn,
        switchOutCurve: Curves.easeOut,
        child: (_isLoading && all.isEmpty) ? loading : content,
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white10,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 120,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        child: Column(
          children: [
            Icon(icon, size: 28, color: color),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgramView extends StatefulWidget {
  final List<Record> records;
  final String? metric;
  final ValueChanged<String?> onMetricChanged;

  const _ProgramView({
    required this.records,
    required this.metric,
    required this.onMetricChanged,
  });

  @override
  _ProgramViewState createState() => _ProgramViewState();
}

class _ProgramViewState extends State<_ProgramView> {
  String? _selectedTask;
  String _searchQuery = '';
  final bool _allExpanded = false;
  final Set<String> _selectedStatuses = {};

  @override
  void initState() {
    super.initState();
    // pick default metric/task if desired
    if (widget.records.isNotEmpty) {
      _selectedTask = widget.records
          .expand((r) => r.tasks)
          .expand((b) => b)
          .map((m) => m.keys.first)
          .firstWhere((_) => true);
    }
  }

  // ── KPI tiles for one program ─────────────────────────────────────
  Widget _programKpiWrap(List<Record> recs) {
    // recs now refers to the list you pass in, not widget.records
    final total = recs.length;
    final failing = recs
        .where((r) =>
            r.failingStateRecords.isNotEmpty &&
            r.failingStateRecords.first.result)
        .length;
    final healthy = total - failing;

    Widget statsCards = Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        _StatCard(
          icon: Icons.error_outline,
          label: 'Failing',
          value: '$failing',
          color: Colors.redAccent,
        ),
        _StatCard(
          icon: Icons.check_circle_outline,
          label: 'Healthy',
          value: '$healthy',
          color: Colors.greenAccent,
        ),
      ],
    );

    // aggregations for THIS program only
    double avg(List<double> v) =>
        v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
    double sum(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b);

    final ramPct = recs
        .where((r) => r.rams.isNotEmpty)
        .expand((r) => r.rams)
        .map<double>((x) => x.percentage)
        .toList();
    final cpu = recs
        .expand((r) => r.cloudwatch['cpu'] ?? [])
        .map<double>((p) => p.value)
        .toList();
    final netIn = recs
        .expand((r) => r.cloudwatch['network_in'] ?? [])
        .map<double>((p) => p.value)
        .toList();
    final netOut = recs
        .expand((r) => r.cloudwatch['network_out'] ?? [])
        .map<double>((p) => p.value)
        .toList();
    final mongo = recs
        .expand((r) => r.checks)
        .map<double>((c) => c.replicationLagMs.toDouble())
        .toList();
    final diskPct =
        recs.expand((r) => r.partitions).map<double>((p) => p.percent).toList();
    final gpuUtil = recs
        .expand((r) => r.tasks)
        .expand((b) => b)
        .where((t) => t['nvidia'] != null)
        .map<double>(
            (t) => (t['nvidia']['average_utilization'] as num).toDouble())
        .toList();
    final rabbitQ = recs.expand((r) => r.rabbitQueues).length.toDouble();

    List<Widget> tiles = [
      Tile(
        label: 'Avg RAM',
        value: avg(ramPct),
        suffix: '%',
        series: ramPct,
        spark: _sparkMini(ramPct),
      ),
      Tile(
        label: 'Avg CPU',
        value: avg(cpu),
        suffix: '%',
        series: cpu,
        spark: _sparkMini(cpu),
      ),
      Tile(
        label: 'Net In',
        value: sum(netIn) / 1e6,
        suffix: ' MB',
        series: netIn,
        spark: _sparkMini(netIn),
      ),
      Tile(
        label: 'Net Out',
        value: sum(netOut) / 1e6,
        suffix: ' MB',
        series: netOut,
        spark: _sparkMini(netOut),
      ),
      Tile(
        label: 'Mongo Lag',
        value: avg(mongo),
        suffix: ' ms',
        series: mongo,
        spark: _sparkMini(mongo),
      ),
      Tile(
        label: 'Peak Disk',
        value: diskPct.isEmpty ? 0 : diskPct.reduce(max),
        suffix: '%',
        series: diskPct,
        spark: _sparkMini(diskPct),
      ),
      Tile(
        label: 'GPU Util',
        value: avg(gpuUtil),
        suffix: '%',
        series: gpuUtil,
        spark: _sparkMini(gpuUtil),
      ),
      Tile(
        label: 'Rabbit Qs',
        value: rabbitQ,
        suffix: '',
        series: const [],
        spark: const SizedBox(height: 30),
      ),
    ];

    final tileWidth = MediaQuery.of(context).size.width < 600 ? 170.0 : 200.0;

    // drop any all‑zeros/NaN metrics
    tiles = tiles.where((t) {
      final Tile tile = t as Tile;
      return !(tile.value.isNaN || tile.value == 0);
    }).toList();

    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        ...tiles.map((t) => SizedBox(width: tileWidth, child: t)),
        statsCards,
      ],
    );
  }

// quick tiny-spark helper (same mini version used in aggregate page)
  Widget _sparkMini(List<double> v) {
    if (v.length <= 1) return const SizedBox(height: 30);
    final spots = List.generate(v.length, (i) => FlSpot(i.toDouble(), v[i]));
    return SizedBox(
        height: 30,
        child: LineChart(LineChartData(
            gridData: const FlGridData(show: false),
            titlesData: const FlTitlesData(show: false),
            borderData: FlBorderData(show: false),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                barWidth: 1.4,
                isCurved: true,
                color: Colors.cyanAccent,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: false),
              )
            ])));
  }

  @override
  Widget build(BuildContext context) {
    final recs = widget.records;

    // 2) build status‑filter chips
    final agg = <String, int>{};
    for (var r in recs) {
      final s = r.stats.first;
      final ok = (s['ok'] as num?)?.toInt() ?? 0;
      final proc = (s['processed'] as num?)?.toInt() ?? 0;
      final fail = (s['failures'] as num?)?.toInt() ?? 0;
      agg.update('ok', (v) => v + ok, ifAbsent: () => ok);
      agg.update('processed', (v) => v + proc, ifAbsent: () => proc);
      agg.update('failures', (v) => v + fail, ifAbsent: () => fail);
    }
    final chips = agg.entries.map((e) {
      final c = _getStyleColor(e.key);
      return FilterChip(
        label: Text('${e.key}: ${e.value}'),
        selected: _selectedStatuses.contains(e.key),
        onSelected: (on) => setState(() {
          if (on) {
            _selectedStatuses.add(e.key);
          } else {
            _selectedStatuses.remove(e.key);
          }
        }),
        backgroundColor: c.withOpacity(0.1),
        selectedColor: c.withOpacity(0.3),
        side: BorderSide(color: c),
        labelStyle: TextStyle(color: c),
      );
    }).toList();

    // 3) apply status + search filters
    var filtered = recs.where((r) {
      if (_selectedStatuses.isNotEmpty) {
        final s = r.stats.first;
        if (!_selectedStatuses.any((k) => ((s[k] as num?)?.toInt() ?? 0) > 0)) {
          return false;
        }
      }
      if (_searchQuery.isNotEmpty &&
          !r.name.toLowerCase().contains(_searchQuery.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      final aF = a.failingStateRecords.isNotEmpty &&
          a.failingStateRecords.first.result;
      final bF = b.failingStateRecords.isNotEmpty &&
          b.failingStateRecords.first.result;
      return (bF ? 1 : 0).compareTo(aF ? 1 : 0);
    });

    // 5) metric/task chart (if you want to keep it)
    final metrics = recs.first.numericMetricKeys.toList()..sort();
    final tasks = recs
        .expand((r) => r.tasks)
        .expand((b) => b)
        .expand((m) => m.keys)
        .toSet()
        .toList()
      ..sort();

    final chart = (widget.metric != null && _selectedTask != null)
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _MetricChart(
              records: recs,
              metric: widget.metric!,
              task: _selectedTask!,
              availableMetrics: metrics,
              availableTasks: tasks,
              onChangedMetric: widget.onMetricChanged,
              onChangedTask: (t) => setState(() => _selectedTask = t),
            ),
          )
        : const SizedBox.shrink();

    // 6) build list
    final listView = ListView.builder(
      padding: const EdgeInsets.only(top: 0),
      itemCount: filtered.length,
      itemBuilder: (_, i) => _MachineCard(
        filtered[i],
        initiallyExpanded: _allExpanded,
      ),
    );

// ─── New: MongoDB average replication‑lag ────────────────────
    final allParts = recs.expand((r) => r.partitions);
    // Group by mount name:
    final Map<String, List<PartitionInfo>> grouped = {};
    for (final p in allParts) {
      grouped.putIfAbsent(p.partition, () => []).add(p);
    }
    // Compute average percent used for each partition:
    final Map<String, double> partitionAvgs = {
      for (final entry in grouped.entries)
        entry.key: entry.value.map((p) => p.percent).reduce((a, b) => a + b) /
            entry.value.length
    };

    for (final p in allParts) {
      grouped.putIfAbsent(p.partition, () => []).add(p);
    }

    final kpiWrap = _programKpiWrap(filtered);

    final searchField = SizedBox(
      width: double.infinity,
      child: TextField(
        onChanged: (v) => setState(() => _searchQuery = v),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: 'Filter servers…',
          filled: true,
          fillColor: Colors.white12,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
        ),
        style: const TextStyle(color: Colors.white),
      ),
    );

    return CustomScrollView(slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        sliver: SliverToBoxAdapter(child: kpiWrap),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        sliver: SliverToBoxAdapter(child: searchField),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        sliver: SliverToBoxAdapter(child: chart),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (ctx, i) => _MachineCard(
            filtered[i],
            initiallyExpanded: _allExpanded,
          ),
          childCount: filtered.length,
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ]);
  }

  Color _getStyleColor(String key) {
    switch (key) {
      case 'ok':
        return Colors.green;
      case 'processed':
        return Colors.blue;
      case 'failures':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}

class TaskTrendPage extends StatelessWidget {
  final Record record;

  const TaskTrendPage({super.key, required this.record});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // make the app bar sit on top of the gradient
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(record.name),
        backgroundColor: Colors.black87,
        elevation: 2,
      ),
      // extend the gradient behind the app bar
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            // top → bottom
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF3A3F44), // charcoal gray
              Color(0xFF2D3136), // slate gray
              Color(0xFF1E2124), // almost black
            ],
          ),
        ),
        child: SafeArea(
          child: TaskTrendContent(record: record),
        ),
      ),
    );
  }
}

// 2) Push that page instead of showing a dialog
class _TaskList extends StatelessWidget {
  final Record record;

  const _TaskList({required this.record});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TaskTrendPage(record: record),
          ),
        );
      },
      icon: const Icon(Icons.list_alt_rounded, size: 18),
      label: const Text('View All Graph Trends'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.cyanAccent.shade700,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        elevation: 4,
        shadowColor: Colors.cyanAccent.shade100,
      ),
    );
  }
}

class TaskTrendDialog {
  static Future<void> show(BuildContext context, Record record) {
    return showGeneralDialog(
      context: context,
      barrierLabel: 'Task Trends',
      barrierDismissible: true,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, anim1, anim2) => Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              width: MediaQuery.of(context).size.width * 0.9,
              height: MediaQuery.of(context).size.height * 0.8,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
              child: Stack(
                children: [
                  // Title + content
                  Positioned.fill(
                    child: Column(
                      children: [
                        // — Title Bar —
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 16, horizontal: 24),
                          child: Text(
                            'Resource Trends for ${record.name}',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.montserrat(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              decoration: TextDecoration.none,
                              // no underline
                              shadows: [
                                Shadow(
                                  color: Colors.black.withOpacity(0.5),
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                          ),
                        ),

                        // subtle divider
                        const Divider(color: Colors.white24, height: 1),

                        // — Your existing TaskTrendContent —
                        Expanded(
                          child: TaskTrendContent(record: record),
                        ),
                      ],
                    ),
                  ),

                  // — Close Button —
                  Positioned(
                    right: 8,
                    top: 8,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim1, anim2, child) =>
          FadeTransition(opacity: anim1, child: child),
    );
  }
}

class TaskTrendContent extends StatefulWidget {
  final Record record;

  const TaskTrendContent({super.key, required this.record});

  @override
  _TaskTrendState createState() => _TaskTrendState();
}

class _TaskTrendState extends State<TaskTrendContent> {
  // Raw RabbitMQ blocks per timestamp
  late final List<List<Map<String, dynamic>>> _rabbitBlocksByTime;

  // Disk partitions dropdown
  String? _selectedPartition;
  late final List<String> _partitionNames;

  // RabbitMQ queues dropdown
  String? _selectedQueue;
  late final List<String> _queueNames;
  late final List<String> _cwMetricNames;
  String? _selectedCWMetric;

  @override
  void initState() {
    super.initState();

    // collect partition names
    _partitionNames = widget.record.tasks
        .expand((batch) => batch.where((t) => t.containsKey('disk')))
        .expand((t) => (t['disk'] as List)
            .cast<Map<String, dynamic>>()
            .map((p) => p['partition'] as String))
        .toSet()
        .toList();
    if (_partitionNames.isNotEmpty) {
      _selectedPartition = _partitionNames.first;
    }

    // group RabbitMQ blocks by timestamp
    _rabbitBlocksByTime = widget.record.tasks
        .map((batch) => batch
            .where((t) => t.containsKey('rabbitmq'))
            .map((t) => t['rabbitmq'] as Map<String, dynamic>)
            .toList())
        .toList();

    // collect all queue names
    _queueNames = _rabbitBlocksByTime
        .expand((blocks) => blocks
            .where((raw) => raw['is_high_queues'] == true)
            .expand((raw) => (raw['high_queues'] as List)
                .cast<Map<String, dynamic>>()
                .map((q) => q['name'] as String)))
        .toSet()
        .toList()
      ..sort();
    if (_queueNames.isNotEmpty) {
      _selectedQueue = _queueNames.first;
    }
    _cwMetricNames = widget.record.cloudwatch.keys.toList()..sort();
    if (_cwMetricNames.isNotEmpty) {
      _selectedCWMetric = _cwMetricNames.first;
    }
  }

  AxisTitles _buildBottomTitles(List<DateTime> times) {
    return AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: 1,
        getTitlesWidget: (value, _) {
          final i = value.toInt();
          if (i >= 0 && i < times.length) {
            final t = times[i];
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                style: const TextStyle(fontSize: 10),
              ),
            );
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }

  /// If unit == 'Bytes', scale by 1024 and append KiB/MiB/GiB/etc + "/s".
  /// Otherwise just prints the number with the given unit.
  String formatValueRate(
    double value, {
    String? unit,
    int decimals = 1,
    bool perSecond = true,
  }) {
    // special path for Bytes
    if (unit?.toUpperCase() == 'BYTES') {
      if (value <= 0) return '0 B${perSecond ? '/s' : ''}';
      const k = 1024.0;
      const suffixes = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
      final i = min((log(value) / log(k)).floor(), suffixes.length - 1);
      final scaled = value / pow(k, i);
      final suffix = suffixes[i] + (perSecond ? '/s' : '');
      return '${scaled.toStringAsFixed(decimals)} $suffix';
    } else if (unit?.toUpperCase() == 'PERCENT') {
      return '$value%';
    }

    // fallback for any other unit (or no unit)
    final formatted = value.toStringAsFixed(decimals);
    if (unit != null && unit.isNotEmpty) {
      return '$formatted $unit';
    }
    return formatted;
  }

  LineChartData _makeChartData(
    List<FlSpot> spots,
    List<DateTime> times, {
    String? unit,
    double? maxY,
  }) {
    return LineChartData(
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        getDrawingHorizontalLine: (y) => FlLine(
          color: Colors.white.withOpacity(0.1),
          strokeWidth: 1,
          dashArray: [5, 3],
        ),
      ),
      borderData: FlBorderData(
        show: true,
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.2)),
        ),
      ),
      titlesData: FlTitlesData(
        bottomTitles: _buildBottomTitles(times),
        leftTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          gradient: LinearGradient(
            colors: [
              Colors.blueAccent.withOpacity(0.6),
              Colors.cyanAccent,
            ],
          ),
          barWidth: 3,
          dotData: FlDotData(
            show: true,
            getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(
              radius: 5,
              color: Colors.cyanAccent,
              strokeWidth: 2,
              strokeColor: Colors.white,
            ),
          ),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.cyanAccent.withOpacity(0.3),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ],
      lineTouchData: LineTouchData(
        handleBuiltInTouches: true,
        touchTooltipData: LineTouchTooltipData(
          tooltipBorderRadius: BorderRadius.circular(8),
          tooltipPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          fitInsideVertically: true,
          getTooltipItems: (touchedSpots) {
            return touchedSpots.map((spot) {
              final label = formatValueRate(
                spot.y,
                unit: unit,
                decimals: 1,
                perSecond: true,
              );
              return LineTooltipItem(
                label,
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      offset: Offset(0, 1),
                      blurRadius: 2,
                      color: Colors.black45,
                    ),
                  ],
                ),
              );
            }).toList();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final times = r.timestamp.map((s) => DateTime.parse(s).toLocal()).toList();

    // MongoDB data
    final totalChecks = r.checks.length;
    final lagSpots = List<FlSpot>.generate(
      totalChecks,
      (i) => FlSpot(i.toDouble(), r.checks[i].replicationLagMs.toDouble()),
    );
    final longRunningSpots = List<FlSpot>.generate(
      totalChecks,
      (i) => FlSpot(i.toDouble(), r.checks[i].longRunning ? 1.0 : 0.0),
    );
    final mongoSummary = totalChecks > 0
        ? Card(
            child: ListTile(
              leading: const Icon(Icons.storage, color: Colors.tealAccent),
              title: Text('MongoDB Role: ${r.checks.first.role.toUpperCase()}'),
              subtitle: Text(
                'Connections OK: ${r.checks.where((c) => c.connection).length}/$totalChecks\n'
                'Avg Rep Lag: ${(r.checks.map((c) => c.replicationLagMs).reduce((a, b) => a + b) / totalChecks).toStringAsFixed(0)} ms\n'
                'Long-running ops: ${r.checks.where((c) => c.longRunning).length}/$totalChecks',
              ),
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('No MongoDB data available',
                style: Theme.of(context).textTheme.bodyMedium),
          );

    List<FlSpot> cwSpots(List<CloudwatchPoint> pts) => List<FlSpot>.generate(
          pts.length,
          (i) => FlSpot(i.toDouble(), pts[i].value),
        );

    final queueTotalSpots = List<FlSpot>.generate(
      r.checks.length,
      (i) => FlSpot(i.toDouble(), r.checks[i].queueTotal.toDouble()),
    );
    final queueReadersSpots = List<FlSpot>.generate(
      r.checks.length,
      (i) => FlSpot(i.toDouble(), r.checks[i].queueReaders.toDouble()),
    );
    final queueWritersSpots = List<FlSpot>.generate(
      r.checks.length,
      (i) => FlSpot(i.toDouble(), r.checks[i].queueWriters.toDouble()),
    );

    // RAM data
    final ramSpots = List<FlSpot>.generate(
      r.rams.length,
      (i) => FlSpot(i.toDouble(), r.rams[i].percentage),
    );

    // Disk partition data
    final hasPartitionInfo =
        r.tasks.any((batch) => batch.any((t) => t.containsKey('disk')));
    final partPercents = List<double>.generate(r.tasks.length, (i) {
      final batch = r.tasks[i];
      final diskTask = batch.firstWhere((t) => t.containsKey('disk'),
          orElse: () => <String, dynamic>{});
      if (diskTask.isEmpty) return 0.0;
      final infos = (diskTask['disk'] as List).cast<Map<String, dynamic>>();
      final partInfo = infos.firstWhere(
          (p) => p['partition'] == _selectedPartition,
          orElse: () => <String, dynamic>{});
      return partInfo.isNotEmpty
          ? (partInfo['percent'] as num).toDouble()
          : 0.0;
    });
    final partSpots = List<FlSpot>.generate(
      partPercents.length,
      (i) => FlSpot(i.toDouble(), partPercents[i]),
    );
    final currentPart = partPercents.isNotEmpty ? partPercents.first : 0.0;
    final avgPart = partPercents.isNotEmpty
        ? partPercents.reduce((a, b) => a + b) / partPercents.length
        : 0.0;

    // RabbitMQ unit selection
    final allMs = _rabbitBlocksByTime
        .expand((blocks) => blocks
            .where((raw) => raw['is_high_queues'] == true)
            .expand((raw) => (raw['high_queues'] as List)
                .cast<Map<String, dynamic>>()
                .map((q) => (q['time_to_complete_ms'] as num).toDouble())))
        .toList();
    final maxMs = allMs.isNotEmpty ? allMs.reduce(max) : 0.0;
    late String unit;
    late double div;
    if (maxMs < 1000) {
      unit = 'ms';
      div = 1;
    } else if (maxMs < 60000) {
      unit = 's';
      div = 1000;
    } else if (maxMs < 3600000) {
      unit = 'min';
      div = 60000;
    } else {
      unit = 'h';
      div = 3600000;
    }

    // RabbitMQ time series for selected queue
    final queueTimeSpots =
        List<FlSpot>.generate(_rabbitBlocksByTime.length, (i) {
      for (final raw in _rabbitBlocksByTime[i]) {
        if (raw['is_high_queues'] == true) {
          final queues =
              (raw['high_queues'] as List).cast<Map<String, dynamic>>();
          final match = queues.firstWhere((q) => q['name'] == _selectedQueue,
              orElse: () => <String, dynamic>{});
          if (match.isNotEmpty) {
            final ms = (match['time_to_complete_ms'] as num).toDouble();
            return FlSpot(i.toDouble(), ms / div);
          }
        }
      }
      return FlSpot(i.toDouble(), 0.0);
    });

    // NVIDIA GPU metrics over time
    final List<FlSpot> gpuUtilSpots = [];
    final List<FlSpot> gpuMemSpots = [];
    final List<FlSpot> gpuTempSpots = [];
    int gpuCount = 0;

    for (int i = 0; i < r.tasks.length; i++) {
      final batch = r.tasks[i];
      final nvidiaTask = batch.firstWhere(
        (t) => t.containsKey('nvidia'),
        orElse: () => {},
      );

      if (nvidiaTask.isNotEmpty) {
        final nvidia = nvidiaTask['nvidia'] as Map<String, dynamic>;
        final util = (nvidia['average_utilization'] as num?)?.toDouble() ?? 0.0;
        final mem = (nvidia['average_memory_used'] as num?)?.toDouble() ?? 0.0;
        final temp = (nvidia['average_temperature'] as num?)?.toDouble() ?? 0.0;
        gpuUtilSpots.add(FlSpot(i.toDouble(), util));
        gpuMemSpots.add(FlSpot(i.toDouble(), mem));
        gpuTempSpots.add(FlSpot(i.toDouble(), temp));
        gpuCount = nvidia['gpu_count'] ?? gpuCount; // remember a value
      }
    }

    return Stack(children: [
      Center(
          child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                      // sizing and padding
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.all(12),
                      // constraints: BoxConstraints(
                      //   maxWidth: 800,
                      //   // so it doesn’t stretch too wide on web/desktop
                      //   maxHeight:
                      //       MediaQuery.of(context).size.height * 0.85,
                      // ),
                      // decoration: BoxDecoration(
                      //   color: Colors.white.withOpacity(0.08),
                      //   borderRadius: BorderRadius.circular(24),
                      //   border:
                      //       Border.all(color: Colors.white.withOpacity(0.2)),
                      // ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            mongoSummary,
                            if (_cwMetricNames.isNotEmpty &&
                                _selectedCWMetric != null) ...[
                              Text(
                                  'CloudWatch • ${_selectedCWMetric!.toUpperCase()}',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              Card(
                                margin: const EdgeInsets.symmetric(vertical: 8),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      // metric dropdown
                                      DropdownButtonFormField<String>(
                                        isExpanded: true,
                                        decoration: const InputDecoration(
                                            labelText: 'Metric'),
                                        value: _selectedCWMetric,
                                        items: _cwMetricNames
                                            .map((m) => DropdownMenuItem(
                                                value: m, child: Text(m)))
                                            .toList(),
                                        onChanged: (v) => setState(
                                            () => _selectedCWMetric = v),
                                      ),
                                      const SizedBox(height: 12),
                                      // line chart
                                      if (widget
                                          .record
                                          .cloudwatch[_selectedCWMetric]!
                                          .isNotEmpty)
                                        SizedBox(
                                          height: 180,
                                          child: LineChart(
                                            _makeChartData(
                                              cwSpots(widget.record.cloudwatch[
                                                      _selectedCWMetric] ??
                                                  []),
                                              // bottom-axis timestamps
                                              widget
                                                  .record
                                                  .cloudwatch[
                                                      _selectedCWMetric]!
                                                  .map((p) => p.ts)
                                                  .toList(),
                                              unit: widget
                                                  .record
                                                  .cloudwatch[
                                                      _selectedCWMetric]!
                                                  .first
                                                  .unit,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            // MongoDB chart
                            const SizedBox(height: 16),
                            if (lagSpots.isNotEmpty) ...[
                              Text('Replication Lag (ms)',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 180,
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: LineChart(
                                      _makeChartData(lagSpots, times,
                                          unit: 'ms'),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                            if (longRunningSpots.isNotEmpty) ...[
                              Text('Long-Running Ops',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 180,
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: LineChart(_makeChartData(
                                        longRunningSpots, times)),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            if (queueTotalSpots.isNotEmpty) ...[
                              Text('MongoDB Queue Size',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 200,
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: LineChart(
                                      LineChartData(
                                        gridData: const FlGridData(show: true),
                                        borderData: FlBorderData(show: false),
                                        titlesData: FlTitlesData(
                                          bottomTitles:
                                              _buildBottomTitles(times),
                                          leftTitles: AxisTitles(
                                            sideTitles: SideTitles(
                                              showTitles: true,
                                              interval: 500,
                                              // adjust based on data range
                                              getTitlesWidget: (value, _) {
                                                if (value >= 1000) {
                                                  return Text(
                                                      '${(value / 1000).toStringAsFixed(1)}K');
                                                } else {
                                                  return Text(
                                                      value.toInt().toString());
                                                }
                                              },
                                              reservedSize:
                                                  40, // ensure enough space
                                            ),
                                          ),
                                        ),
                                        lineBarsData: [
                                          LineChartBarData(
                                            spots: queueTotalSpots,
                                            isCurved: true,
                                            dotData:
                                                const FlDotData(show: false),
                                            barWidth: 2,
                                            color: Colors.blue,
                                          ),
                                          LineChartBarData(
                                            spots: queueReadersSpots,
                                            isCurved: true,
                                            dotData:
                                                const FlDotData(show: false),
                                            barWidth: 2,
                                            color: Colors.green,
                                          ),
                                          LineChartBarData(
                                            spots: queueWritersSpots,
                                            isCurved: true,
                                            dotData:
                                                const FlDotData(show: false),
                                            barWidth: 2,
                                            color: Colors.red,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  LegendDot(color: Colors.blue, label: 'Total'),
                                  LegendDot(
                                    color: Colors.green,
                                    label: 'Readers',
                                  ),
                                  LegendDot(
                                      color: Colors.red, label: 'Writers'),
                                ],
                              ),
                              const SizedBox(height: 16),
                            ],

                            if (gpuUtilSpots.isNotEmpty) ...[
                              Text('NVIDIA GPU Metrics (x$gpuCount)',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              Card(
                                margin: const EdgeInsets.symmetric(vertical: 8),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    children: [
                                      SizedBox(
                                        height: 180,
                                        child: LineChart(
                                          LineChartData(
                                            gridData:
                                                const FlGridData(show: true),
                                            lineTouchData: LineTouchData(
                                              enabled: true,
                                              touchTooltipData:
                                                  LineTouchTooltipData(
                                                // tooltipBgColor: Colors.black87,
                                                tooltipBorderRadius:
                                                    BorderRadius.circular(8),
                                                getTooltipItems:
                                                    (touchedSpots) {
                                                  return touchedSpots
                                                      .map((spot) {
                                                    final value = spot.y
                                                        .toStringAsFixed(1);
                                                    String label;
                                                    switch (spot.barIndex) {
                                                      case 0:
                                                        label = 'Util: $value%';
                                                        break;
                                                      case 1:
                                                        label =
                                                            'Memory: $value GB';
                                                        break;
                                                      case 2:
                                                        label =
                                                            'Temp: $value °C';
                                                        break;
                                                      default:
                                                        label = value;
                                                    }

                                                    return LineTooltipItem(
                                                      label,
                                                      const TextStyle(
                                                          color: Colors.white),
                                                    );
                                                  }).toList();
                                                },
                                              ),
                                            ),
                                            borderData:
                                                FlBorderData(show: false),
                                            titlesData: FlTitlesData(
                                              bottomTitles:
                                                  _buildBottomTitles(times),
                                              leftTitles: AxisTitles(
                                                sideTitles: SideTitles(
                                                  showTitles: true,
                                                  reservedSize: 36,
                                                  getTitlesWidget: (v, _) =>
                                                      Text(
                                                          v.toStringAsFixed(0)),
                                                ),
                                              ),
                                            ),
                                            lineBarsData: [
                                              LineChartBarData(
                                                spots: gpuUtilSpots,
                                                isCurved: true,
                                                color: Colors.blue,
                                                barWidth: 2,
                                                dotData: const FlDotData(
                                                    show: false),
                                              ),
                                              LineChartBarData(
                                                spots: gpuMemSpots,
                                                isCurved: true,
                                                color: Colors.green,
                                                barWidth: 2,
                                                dotData: const FlDotData(
                                                    show: false),
                                              ),
                                              LineChartBarData(
                                                spots: gpuTempSpots,
                                                isCurved: true,
                                                color: Colors.red,
                                                barWidth: 2,
                                                dotData: const FlDotData(
                                                    show: false),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceEvenly,
                                        children: [
                                          LegendDot(
                                              color: Colors.blue,
                                              label: 'Utilization (%)'),
                                          LegendDot(
                                              color: Colors.green,
                                              label: 'Memory (GB)'),
                                          LegendDot(
                                              color: Colors.red,
                                              label: 'Temperature (°C)'),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],

                            // RAM chart
                            if (ramSpots.isNotEmpty) ...[
                              Text('RAM Usage (%)',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 180,
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: LineChart(
                                        _makeChartData(ramSpots, times)),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            // Disk partition chart
                            Text('Partition Usage (%)',
                                style: Theme.of(context).textTheme.titleLarge),
                            const SizedBox(height: 8),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: hasPartitionInfo
                                    ? Column(
                                        children: [
                                          ListTile(
                                            title: Text(
                                                'Mount: $_selectedPartition'),
                                            subtitle: Text(
                                              'Current: ${currentPart.toStringAsFixed(1)}%   Avg: ${avgPart.toStringAsFixed(1)}%',
                                            ),
                                          ),
                                          DropdownButtonFormField<String>(
                                            decoration: const InputDecoration(
                                                labelText: 'Partition'),
                                            isExpanded: true,
                                            value: _selectedPartition,
                                            items: _partitionNames
                                                .map((p) => DropdownMenuItem(
                                                      value: p,
                                                      child: Text(p),
                                                    ))
                                                .toList(),
                                            onChanged: (v) => setState(
                                                () => _selectedPartition = v),
                                          ),
                                          const SizedBox(height: 8),
                                          SizedBox(
                                            height: 150,
                                            child: LineChart(_makeChartData(
                                                partSpots, times)),
                                          ),
                                        ],
                                      )
                                    : Center(
                                        child: Text(
                                            'No partition info available',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // RabbitMQ per-queue chart
                            if (_queueNames.isNotEmpty) ...[
                              Text('RabbitMQ: $_selectedQueue (in $unit)',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              Card(
                                margin: const EdgeInsets.symmetric(vertical: 8),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      DropdownButtonFormField<String>(
                                        decoration: const InputDecoration(
                                            labelText: 'Queue Name'),
                                        isExpanded: true,
                                        value: _selectedQueue,
                                        items: _queueNames
                                            .map((q) => DropdownMenuItem(
                                                  value: q,
                                                  child: Text(q),
                                                ))
                                            .toList(),
                                        onChanged: (v) =>
                                            setState(() => _selectedQueue = v),
                                      ),
                                      const SizedBox(height: 16),
                                      SizedBox(
                                        height: 180,
                                        child: LineChart(
                                          _makeChartData(
                                            queueTimeSpots,
                                            times,
                                            unit: unit,
                                            maxY: queueTimeSpots
                                                .map((s) => s.y)
                                                .reduce(
                                                    (a, b) => a > b ? a : b),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      )))))
    ]);
  }
}

class _DynamicObject extends StatelessWidget {
  final dynamic data;

  const _DynamicObject({required this.data});

  @override
  Widget build(BuildContext context) {
    if (data is Map<String, dynamic>) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: (data as Map<String, dynamic>)
            .entries
            .map<Widget>((e) => _DynamicEntry(e.key, e.value))
            .toList(),
      );
    }
    if (data is List) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < data.length; ++i) _DynamicEntry('[$i]', data[i])
        ],
      );
    }
    return SelectableText(
      data.toString(),
      style: const TextStyle(color: Colors.black),
    );
  }
}

class _DynamicEntry extends StatelessWidget {
  final String k;
  final dynamic v;

  const _DynamicEntry(this.k, this.v);

  @override
  Widget build(BuildContext context) {
    if (v is Map || v is List) {
      return ExpansionTile(
        tilePadding: const EdgeInsets.only(left: 8),
        title: Text(
          k,
          style:
              const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        children: [
          Padding(
              padding: const EdgeInsets.only(left: 16),
              child: _DynamicObject(data: v))
        ],
      );
    }
    return ListTile(
      dense: true,
      title: Text(
        k,
        style: const TextStyle(color: Colors.black),
      ),
      trailing: Text(
        v.toString(),
        style: const TextStyle(color: Colors.black),
      ),
    );
  }
}

class _MachineCard extends StatefulWidget {
  final Record record;
  final bool initiallyExpanded;

  const _MachineCard(this.record, {this.initiallyExpanded = false});

  @override
  State<_MachineCard> createState() => _MachineCardState();
}

class _MachineCardState extends State<_MachineCard> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    final hasWarn = widget.record.failingStateRecords.any((fs) => fs.result);

    _isExpanded = widget.initiallyExpanded || hasWarn;
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;

    // find the most recent failing-state, if any
    final latestFail = record.failingStateRecords.isNotEmpty
        ? record.failingStateRecords.first
        : null;

    // parse the record’s last-update time
    final lastUpdate = DateTime.parse(record.timestamp.first).toLocal();

    // only flag as warning if that failure is _after_ the last update
    final hasWarn = latestFail != null &&
        latestFail.result &&
        (latestFail.timestamp.isAfter(lastUpdate) ||
            latestFail.timestamp.isAtSameMomentAs(lastUpdate));

    final stat = record.stats.first;
    final proc = (stat['processed'] as num?)?.toInt() ?? 0;
    final ok = (stat['ok'] as num?)?.toInt() ?? 0;
    final fail = max(proc - ok, 0);

    final statusBubble = Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: hasWarn ? Colors.red : Colors.green,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          '${fail > 0 ? fail : ok}',
          style: const TextStyle(
              color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ),
    );

    final leading = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: fail > 0 ? '$fail failure(s)' : '$ok success(es)',
          child: statusBubble,
        ),
        if (hasWarn) ...[
          const SizedBox(width: 4),
          const Tooltip(
            message: 'One or more checks failing',
            child: Icon(Icons.warning_amber_rounded,
                color: Colors.orange, size: 20),
          ),
        ],
      ],
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF2E2E48).withOpacity(0.75),
            const Color(0xFF1C1C2D).withOpacity(0.75)
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: hasWarn ? Colors.orange : Colors.transparent,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        initiallyExpanded: _isExpanded || hasWarn,
        onExpansionChanged: (val) => setState(() => _isExpanded = val),
        leading: leading,
        title: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [Colors.cyanAccent, Colors.purpleAccent],
                ).createShader(bounds),
                child: Text(
                  record.name,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.cloud_outlined,
                      color: Colors.lightBlueAccent, size: 20),
                  const SizedBox(width: 8),
                  SelectableText(
                    record.ip,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.deepPurpleAccent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      record.instancetype,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _InfoRow(
                icon: Icons.access_time,
                label: "Launched",
                value:
                    timeago.format(DateTime.parse(record.launchtime).toLocal()),
              ),
              const SizedBox(height: 6),
              _InfoRow(
                icon: Icons.update,
                label: "Last Update",
                value: timeago
                    .format(DateTime.parse(record.timestamp.first).toLocal()),
              ),
            ],
          ),
        ),
        children: [
          if (record.stats.isNotEmpty) _StatsRow(record.stats.first),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.auto_graph_rounded),
            label: const Text('Scale Smart'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurpleAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            onPressed: () => ScaleRecommendationDialog.show(
              context,
              instanceId: record.instanceId,
              instanceType: record.instancetype,
            ),
          ),
          const SizedBox(height: 8),
          if (record.tasks.any((b) => b.isNotEmpty)) _TaskList(record: record),
          if (record.failingStateRecords.isNotEmpty)
            _FailingStatesWidget(
                failingStateRecords: record.failingStateRecords,
                lastUpdate: DateTime.parse(record.timestamp.first).toLocal()),
        ],
      ),
    );
  }

  /// Reusable info row widget
  Widget _InfoRow(
      {required IconData icon, required String label, required String value}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey[300]),
        const SizedBox(width: 6),
        Text(
          "$label: $value",
          style: TextStyle(color: Colors.grey[300], fontSize: 13.5),
        ),
      ],
    );
  }
}

class _MetricChart extends StatelessWidget {
  final List<Record> records;
  final String metric;
  final String task;
  final List<String> availableMetrics;
  final List<String> availableTasks;
  final ValueChanged<String?> onChangedMetric;
  final ValueChanged<String> onChangedTask;

  const _MetricChart({
    required this.records,
    required this.metric,
    required this.task,
    required this.availableMetrics,
    required this.availableTasks,
    required this.onChangedMetric,
    required this.onChangedTask,
  });

  @override
  Widget build(BuildContext context) {
    // build spots exactly as before
    final spots = <FlSpot>[];
    int idx = 0;
    for (final r in records) {
      final v = r.metricValue(metric);
      if (v != null) {
        spots.add(FlSpot(idx.toDouble(), v));
      }
      idx++;
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min, // <-- shrink-wrap vertically
          children: [
            // Row of two dropdowns
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: metric,
                    decoration: const InputDecoration(
                      labelText: 'Metric',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: onChangedMetric,
                    items: availableMetrics
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Text(m),
                            ))
                        .toList(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: task,
                    decoration: const InputDecoration(
                      labelText: 'Task',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (t) => onChangedTask(t!),
                    items: availableTasks
                        .map((t) => DropdownMenuItem(
                              value: t,
                              child: Text(t),
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Fixed‐height container for the chart
            SizedBox(
              height: 180,
              child: LineChart(
                LineChartData(
                  gridData: const FlGridData(show: true),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 1,
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          if (i >= 0 && i < spots.length) {
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                i.toString(),
                                style: const TextStyle(fontSize: 10),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                  lineTouchData: LineTouchData(
                    handleBuiltInTouches: true,
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => Colors.black.withOpacity(0.7),
                      getTooltipItems: (touchedSpots) => touchedSpots
                          .map((e) => LineTooltipItem(
                                '${e.x.toInt()}\n${e.y.toStringAsFixed(2)}',
                                const TextStyle(color: Colors.white),
                              ))
                          .toList(),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      isCurved: true,
                      gradient: const LinearGradient(
                        colors: [Color(0xFF40C4FF), Color(0xFF2962FF)],
                      ),
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            const Color(0xFF40C4FF).withOpacity(0.5),
                            Colors.transparent
                          ],
                        ),
                      ),
                      spots: spots,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final Map<String, dynamic> stats;

  const _StatsRow(this.stats);

  @override
  Widget build(BuildContext context) {
    final children = stats.entries.map((e) {
      final value = e.value;
      final color = _getStyleColor(e.key);

      return Chip(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        label: Text('${e.key}: $value'),
        backgroundColor: color.withOpacity(0.1),
        side: BorderSide(color: color),
        labelStyle: TextStyle(color: color, fontSize: 12),
      );
    }).toList();
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }

  Color _getStyleColor(String e) {
    switch (e) {
      case 'ok':
        return Colors.green;
      case 'processed':
        return Colors.blue;
      case 'failures':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }
}

/// Models for parsed task data
class PartitionInfo {
  final String partition;
  final String device;
  final int total;
  final int used;
  final int available;
  final double percent;

  PartitionInfo.fromJson(Map<String, dynamic> json)
      : partition = json['partition'],
        device = json['device'],
        total = json['total'],
        used = json['used'],
        available = json['available'],
        percent = (json['percent'] as num).toDouble();
}

class CloudwatchPoint {
  final DateTime ts;
  final double value;
  final String unit;

  CloudwatchPoint({
    required this.ts,
    required this.value,
    required this.unit,
  });

  factory CloudwatchPoint.fromJson(Map<String, dynamic> json) =>
      CloudwatchPoint(
        ts: DateTime.parse(json['Timestamp'] as String).toLocal(),
        value: (json['Value'] as num).toDouble(),
        unit: json['Unit'] as String,
      );
}

class RamInfo {
  final double total;
  final double used;
  final double available;
  final double percentage;

  RamInfo.fromJson(Map<String, dynamic> json)
      : total = (json['total'] as num).toDouble(),
        used = (json['used'] as num).toDouble(),
        available = (json['available'] as num).toDouble(),
        percentage = (json['percentage'] as num).toDouble();
}

class MongoCheck {
  final String role;
  final bool connection;
  final bool connections;
  final bool longRunning;
  final bool replicationLag;
  final int replicationLagMs;
  final int queueTotal;
  final int queueReaders;
  final int queueWriters;

  MongoCheck.fromJson(Map<String, dynamic> json)
      : role = json['role'] as String,
        connection = json['connection'] as bool,
        connections = json['connections'] as bool,
        longRunning = json['long_running_operations'] as bool,
        replicationLag = json['replication_lag'] as bool,
        replicationLagMs = json['replication_lag_ms'] as int,
        queueTotal = (json['queue_size']?['total'] ?? 0) as int,
        queueReaders = (json['queue_size']?['readers'] ?? 0) as int,
        queueWriters = (json['queue_size']?['writers'] ?? 0) as int;
}

class TaskAggregateView extends StatelessWidget {
  final List<Record> records;

  const TaskAggregateView({super.key, required this.records});

  @override
  Widget build(BuildContext context) {
    // ─── Partition aggregation ─────────────────────────────────────────────
    final Map<String, List<PartitionInfo>> grouped = {};
    for (var r in records) {
      for (var p in r.partitions) {
        grouped.putIfAbsent(p.partition, () => []).add(p);
      }
    }
    final partitionRows = grouped.entries.isNotEmpty
        ? grouped.entries.map((e) {
            final list = e.value;
            final avgUsed =
                list.map((p) => p.used).reduce((a, b) => a + b) / list.length;
            final avgPercent =
                list.map((p) => p.percent).reduce((a, b) => a + b) /
                    list.length;
            return DataRow(cells: [
              DataCell(Text(e.key)),
              DataCell(Text(avgUsed.toStringAsFixed(0))),
              DataCell(Text('${avgPercent.toStringAsFixed(1)}%')),
            ]);
          }).toList()
        : <DataRow>[];

    // ─── RAM aggregation ────────────────────────────────────────────────────
    final ramful = records.where((r) => r.rams.isNotEmpty).toList();
    final avgRam = ramful.isNotEmpty
        ? ramful
                .map((r) =>
                    r.rams.map((x) => x.percentage).reduce((a, b) => a + b) /
                    r.rams.length)
                .reduce((a, b) => a + b) /
            ramful.length
        : 0.0;

    // ─── MongoDB aggregation ────────────────────────────────────────────────
    final totalChecks = records.fold<int>(0, (sum, r) => sum + r.checks.length);
    final sumLagMs = records.fold<int>(
      0,
      (sum, r) => sum + r.checks.fold<int>(0, (s, c) => s + c.replicationLagMs),
    );
    final avgLagMs = totalChecks > 0 ? sumLagMs / totalChecks : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Partition table
          Text('Partition Usage (avg)',
              style: Theme.of(context).textTheme.titleLarge),
          Card(
            child: grouped.isNotEmpty
                ? DataTable(
                    columns: const [
                      DataColumn(label: Text('Partition')),
                      DataColumn(label: Text('Avg Used')),
                      DataColumn(label: Text('Avg %')),
                    ],
                    rows: partitionRows,
                  )
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No partition info available',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
          ),

          const SizedBox(height: 16),

          // RAM Utilization
          Text('RAM Utilization (avg %)',
              style: Theme.of(context).textTheme.titleLarge),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ramful.isNotEmpty
                  ? Text('${avgRam.toStringAsFixed(1)}%',
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold))
                  : Text(
                      'No RAM info available',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
            ),
          ),

          const SizedBox(height: 16),

          // Mongo checks summary
          if (totalChecks > 0) ...[
            Text('Mongo Checks', style: Theme.of(context).textTheme.titleLarge),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        // center horizontally
                        children: [
                          Text(
                            'Avg Replication Lag (ms)',
                            style: Theme.of(context).textTheme.titleLarge,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${avgLagMs.toStringAsFixed(1)} ms',
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            )
          ] else ...[
            const SizedBox()
          ],
        ],
      ),
    );
  }
}

class SpaceMonitorOverlay extends StatefulWidget {
  final List<Record> records;

  const SpaceMonitorOverlay({super.key, required this.records});

  @override
  _SpaceMonitorOverlayState createState() => _SpaceMonitorOverlayState();
}

class _SpaceMonitorOverlayState extends State<SpaceMonitorOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late List<_ServerStar> _stars;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
    _buildStars();
  }

  void _buildStars() {
    _stars = List.generate(widget.records.length, (i) {
      final rec = widget.records[i];
      final failing = rec.failingStateRecords.isNotEmpty &&
          rec.failingStateRecords.first.result;
      return _ServerStar(
        seed: i,
        isFailing: failing,
        label: rec.program,
      );
    });
    // Randomize draw order once
    _stars.shuffle(Random());
  }

  @override
  void didUpdateWidget(covariant SpaceMonitorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.records, widget.records)) {
      _buildStars();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        size: MediaQuery.of(context).size,
        painter: _OverlayPainter(
          phase: _ctrl.value * 2 * pi,
          stars: _stars,
        ),
      ),
    );
  }
}

/// Represents one server as a drifting star.
class _ServerStar {
  final double x0, y0, z0;
  final bool isFailing;
  final String label;

  _ServerStar({
    required int seed,
    required this.isFailing,
    required this.label,
  })  : x0 = _rand(seed, 0, -1, 1),
        y0 = _rand(seed, 1, -1, 1),
        z0 = _rand(seed, 2, 0, 1);

  static double _rand(int seed, int idx, double min, double max) {
    final rnd = Random(seed + idx);
    return min + (max - min) * rnd.nextDouble();
  }

  /// Project into 2D; returns null if behind viewer.
  Offset? projected(double phase, Size sz) {
    final z = (z0 + phase / (2 * pi)) % 1.0;
    if (z < 0.1) return null;
    final px = x0 / z, py = y0 / z;
    final sx = (px * 0.5 + 0.5) * sz.width;
    final sy = (py * 0.5 + 0.5) * sz.height;
    return Offset(sx, sy);
  }

  /// Apparent radius based on depth.
  double size(double phase) {
    final z = (z0 + phase / (2 * pi)) % 1.0;
    return (1.2 - z) * (isFailing ? 5.0 : 3.0);
  }

  Color get color => isFailing
      ? Colors.redAccent.withOpacity(0.9)
      : Colors.lightGreenAccent.withOpacity(0.8);
}

class _OverlayPainter extends CustomPainter {
  final double phase;
  final List<_ServerStar> stars;

  _OverlayPainter({required this.phase, required this.stars});

  @override
  void paint(Canvas canvas, Size size) {
    for (var star in stars) {
      final pos = star.projected(phase, size);
      if (pos == null) continue;
      final r = star.size(phase);

      // 1) draw the star
      canvas.drawCircle(pos, r, Paint()..color = star.color);

      // 2) label only failing stars
      if (star.isFailing) {
        final tp = TextPainter(
          text: TextSpan(
            text: star.label,
            style: TextStyle(
              color: Colors.redAccent.withOpacity(0.9),
              fontSize: 12,
              fontWeight: FontWeight.bold,
              shadows: [
                Shadow(
                  color: Colors.black.withOpacity(0.7),
                  blurRadius: 2,
                ),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final to = pos.translate(-tp.width / 2, -r - tp.height - 4);
        tp.paint(canvas, to);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}
