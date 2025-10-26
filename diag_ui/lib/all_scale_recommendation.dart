import 'dart:async'; // NEW: Timer & Stream for auto-refresh
import 'dart:convert';
import 'dart:ui';

import 'package:advanced_ai_diagnostics/ui_elements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shimmer/shimmer.dart';

import 'action_dialog.dart';
import 'main.dart';

/// ------------------------------------------------------------
///  SCALE RECOMMENDATIONS — Glass-morphic, Animated, Icon-rich
/// ------------------------------------------------------------
class RecommendationsPage extends StatefulWidget {
  const RecommendationsPage({super.key});

  @override
  State<RecommendationsPage> createState() => _RecommendationsPageState();
}

class _RecommendationsPageState extends State<RecommendationsPage> {
  final StreamController<List<Recommendation>> _recsController =
      StreamController<List<Recommendation>>.broadcast();
  Timer? _refreshTimer;

  bool _showScaleDown = true;
  Set<String> _selectedIds = <String>{};
  List<Recommendation> _lastRecs = [];
  bool _initializedSelection = false;

  @override
  void initState() {
    super.initState();
    _startStreaming();
  }

  void _startStreaming() {
    _fetchAndAdd();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _fetchAndAdd());
  }

  Future<void> _fetchAndAdd() async {
    try {
      final recs = await _fetchRecommendations();
      if (mounted) {
        setState(() {
          _lastRecs = recs;
          // Remove any selections no longer in the list
          _selectedIds
              .removeWhere((id) => recs.every((r) => r.instanceId != id));

          // On first load, auto-select all in the current filter
          if (!_initializedSelection) {
            _selectedIds = recs
                .where((r) =>
                    _showScaleDown ? r.hourlySavings > 0 : r.hourlySavings < 0)
                .map((r) => r.instanceId)
                .toSet();
            _initializedSelection = true;
          }
        });
        _recsController.sink.add(recs);
      }
    } catch (e) {
      if (mounted) {
        showGlassMorphicDialog(
          context: context,
          message: 'Error: $e',
          type: DialogType.error,
        );
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _recsController.close();
    super.dispose();
  }

  Future<List<Recommendation>> _fetchRecommendations() async {
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token');
    if (token == null) throw Exception('No token found');

    final res = await http.get(
      Uri.parse('$urlEndPoint/scale/recommendations/'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (res.statusCode != 200) {
      await storage.delete(key: 'access_token');
      Future.microtask(() {
        if (mounted) {
          navigatorKey.currentState
              ?.pushNamedAndRemoveUntil('/login', (_) => false);
        }
      });
      throw Exception('HTTP ${res.statusCode}: Could not load');
    }
    final decoded =
        json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return (decoded['results'] as List)
        .map((e) => Recommendation.fromJson(e))
        .toList();
  }

  double _calcSelectedTotal(List<Recommendation> recs) {
    return recs
        .where((r) => _selectedIds.contains(r.instanceId))
        .fold(0.0, (sum, r) => sum + r.hourlySavings * 24 * 30);
  }

  Widget _buildFabGroup(List<Recommendation> recs) {
    final children = <Widget>[
      FloatingActionButton.extended(
        heroTag: 'generate_btn',
        onPressed: _generateRecommendations,
        backgroundColor: const Color(0xFF00c6ff),
        icon: const Icon(LucideIcons.sparkles),
        label: const Text('Generate Recommendations'),
      ),
    ];

    if (recs.isNotEmpty) {
      final total = _calcSelectedTotal(recs);
      final formattedTotal =
          NumberFormat.currency(symbol: '\$', decimalDigits: 2).format(total);
      children.add(const SizedBox(height: 12));
      children.add(
        FloatingActionButton.extended(
          heroTag: 'apply_all_btn',
          onPressed: () => _applyAll(recs),
          icon: const Icon(LucideIcons.checkSquare),
          label: Text('Apply All • $formattedTotal/mo'),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: children,
    );
  }

  /// Updated to call the single-instance confirm endpoint in a loop
  Future<void> _applyAll(List<Recommendation> recs) async {
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token') ?? '';
    // Only apply to those the user has selected
    final selectedRecs =
        recs.where((r) => _selectedIds.contains(r.instanceId)).toList();

    for (final rec in selectedRecs) {
      try {
        final resp = await http.post(
          Uri.parse('$urlEndPoint/scale/confirm/'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'instance_id': rec.instanceId,
            'apply_instance_change': true,
            'apply_volume_ids': [],
          }),
        );
        final detail = jsonDecode(resp.body)['detail'];
        if (mounted) {
          showGlassMorphicDialog(
            context: context,
            message: detail,
            type:
                resp.statusCode == 200 ? DialogType.success : DialogType.error,
          );
        }
      } catch (e) {
        if (mounted) {
          showGlassMorphicDialog(
            context: context,
            message: e.toString(),
            type: DialogType.error,
          );
        }
      }
    }

    // Refresh afterwards
    _fetchAndAdd();
  }

  Future<void> _generateRecommendations() async {
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token') ?? '';
    try {
      final res = await http.get(
        Uri.parse('$urlEndPoint/scale/recommendation/?instance_id=all'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (res.statusCode == 200 && mounted) {
        showGlassMorphicDialog(
          context: context,
          message:
              '✨ Generating fresh recommendations… Please check back in a few.',
          type: DialogType.success,
        );
      } else {
        throw Exception('Generation failed: ${res.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        showGlassMorphicDialog(
          context: context,
          message: '$e',
          type: DialogType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final topOffset = MediaQuery.of(context).padding.top + 120 + 16;

    return Scaffold(
      extendBodyBehindAppBar: true,
      floatingActionButton: StreamBuilder<List<Recommendation>>(
        stream: _recsController.stream,
        builder: (ctx, snap) {
          final recs = snap.data ?? [];
          final filtered = recs
              .where((r) =>
                  _showScaleDown ? r.hourlySavings > 0 : r.hourlySavings < 0)
              .toList();
          return _buildFabGroup(filtered);
        },
      ),
      bottomNavigationBar: StreamBuilder<List<Recommendation>>(
        stream: _recsController.stream,
        builder: (ctx, snap) {
          final recs = snap.data ?? [];
          final filtered = recs
              .where((r) =>
                  _showScaleDown ? r.hourlySavings > 0 : r.hourlySavings < 0)
              .toList();
          final total = _calcSelectedTotal(filtered);
          final formattedTotal =
              NumberFormat.currency(symbol: '\$', decimalDigits: 2)
                  .format(total);
          return Container(
            padding: const EdgeInsets.all(16),
            color: Colors.black87,
            child: Text(
              'Price Difference: $formattedTotal/mo',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          );
        },
      ),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(120),
        child: ClipPath(
          clipper: _WaveClipper(),
          child: Container(
            padding: const EdgeInsets.only(top: 40),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00c6ff).withOpacity(0.6),
                  const Color(0xFF0072ff).withOpacity(0.6)
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Align(
                  alignment: Alignment.center,
                  child: Text(
                    'Scale Recommendations',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: Colors.white),
                  ),
                ),
                Positioned(
                  left: 6,
                  top: 0,
                  child: IconButton(
                    icon: const Icon(LucideIcons.arrowLeft),
                    color: Colors.white,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          const AnimatedSpaceBackground(),
          const SatelliteOverlay(),
          Column(
            children: [
              SizedBox(height: topOffset),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Center(
                  child: Wrap(
                    spacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      ChoiceChip(
                        label: const Text('Scale Down'),
                        selected: _showScaleDown,
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                        selectedColor: Colors.green,
                        backgroundColor: Colors.green.withOpacity(0.25),
                        labelStyle: TextStyle(
                          color: _showScaleDown ? Colors.white : Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                        onSelected: (v) {
                          if (!v) return;
                          setState(() {
                            _showScaleDown = true;
                            _selectedIds = _lastRecs
                                .where((r) => r.hourlySavings > 0)
                                .map((r) => r.instanceId)
                                .toSet();
                          });
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Scale Up'),
                        selected: !_showScaleDown,
                        padding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                        selectedColor: const Color(0xFFFF5252),
                        backgroundColor:
                            const Color(0xFFFF5252).withOpacity(0.25),
                        labelStyle: TextStyle(
                          color:
                              !_showScaleDown ? Colors.white : Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                        onSelected: (v) {
                          if (!v) return;
                          setState(() {
                            _showScaleDown = false;
                            _selectedIds = _lastRecs
                                .where((r) => r.hourlySavings < 0)
                                .map((r) => r.instanceId)
                                .toSet();
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  color: const Color(0xFF1de9b6),
                  onRefresh: () => _fetchAndAdd(),
                  child: StreamBuilder<List<Recommendation>>(
                    stream: _recsController.stream,
                    builder: (ctx, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return _buildShimmer();
                      }
                      if (snap.hasError) {
                        return Center(
                          child: Text('Error: ${snap.error}',
                              style: const TextStyle(color: Colors.redAccent)),
                        );
                      }
                      final recs = snap.data!;
                      final filtered = recs
                          .where((r) => _showScaleDown
                              ? r.hourlySavings > 0
                              : r.hourlySavings < 0)
                          .toList();
                      if (filtered.isEmpty) {
                        return const Center(
                            child:
                                Text('🎈 No recommendations for this filter'));
                      }
                      return ListView.separated(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 18),
                        itemBuilder: (_, i) {
                          final rec = filtered[i];
                          return _RecommendationCard(
                            rec: rec,
                            selected: _selectedIds.contains(rec.instanceId),
                            onSelected: (sel) {
                              setState(() {
                                if (sel) {
                                  _selectedIds.add(rec.instanceId);
                                } else {
                                  _selectedIds.remove(rec.instanceId);
                                }
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// ---------- LOADING PLACEHOLDER ----------
  Widget _buildShimmer() => Shimmer.fromColors(
        baseColor: Colors.grey.shade800,
        highlightColor: Colors.grey.shade700,
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 140, 16, 160),
          itemCount: 4,
          itemBuilder: (_, __) => Container(
            height: 80,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.grey.shade900,
              borderRadius: BorderRadius.circular(28),
            ),
          ),
        ),
      );
}

class _RecommendationCard extends StatefulWidget {
  final Recommendation rec;
  final bool selected;
  final ValueChanged<bool> onSelected;

  const _RecommendationCard({
    required this.rec,
    required this.selected,
    required this.onSelected,
  });

  @override
  State<_RecommendationCard> createState() => _RecommendationCardState();
}

class _RecommendationCardState extends State<_RecommendationCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _controller;
  late Animation<double> _arrowAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _arrowAnim = Tween<double>(begin: 0, end: 0.5)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.rec;
    final monthly = rec.hourlySavings * 24 * 30;
    final bool scaleUp = rec.hourlySavings < 0;
    final Color actionColor;
    final String actionText;

    if (rec.currentInstance == rec.newInstance) {
      actionColor = Colors.grey;
      actionText = 'No Change';
    } else if (scaleUp) {
      actionColor = Colors.redAccent;
      actionText = 'Scale Up';
    } else {
      actionColor = Colors.greenAccent;
      actionText = 'Scale Down';
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _expanded = !_expanded;
          _expanded ? _controller.forward() : _controller.reverse();
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.all(1.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            colors: [
              Colors.white.withOpacity(0.25),
              Colors.white.withOpacity(0.05)
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.04)),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                    child: Row(
                      children: [
                        Checkbox(
                          value: widget.selected,
                          onChanged: (v) => widget.onSelected(v ?? false),
                          activeColor: actionColor,
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                "${rec.name} | ${rec.instanceId}",
                                style: const TextStyle(
                                    fontSize: 15, color: Colors.white70),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${rec.currentInstance} → ${rec.newInstance}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _StatusPill(text: actionText, color: actionColor),
                            const SizedBox(height: 6),
                            Text(
                              '\$${monthly.toStringAsFixed(2)}/mo',
                              style: const TextStyle(
                                  color: Colors.greenAccent,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        RotationTransition(
                          turns: _arrowAnim,
                          child: const Icon(Icons.expand_more,
                              color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  AnimatedCrossFade(
                    firstChild: const SizedBox.shrink(),
                    secondChild: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _InfoChip(
                                  icon: LucideIcons.cpu,
                                  label: '${rec.vcpus} vCPU'),
                              _InfoChip(
                                  icon: LucideIcons.server,
                                  label:
                                      '${rec.memoryGiB.toStringAsFixed(0)} GiB RAM'),
                              _InfoChip(
                                  icon: LucideIcons.dollarSign,
                                  label:
                                      '\$${rec.hourlySavings.toStringAsFixed(4)}/h'),
                              _InfoChip(
                                  icon: LucideIcons.calendarDays,
                                  label: '\$${monthly.toStringAsFixed(2)}/mo'),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Text(rec.reason,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ),
                    crossFadeState: _expanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                    duration: const Duration(milliseconds: 300),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF00c6ff), Color(0xFF0072ff)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: Colors.white))
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String text;
  final Color color;

  const _StatusPill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style:
            TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}

class _WaveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = Path();
    path.lineTo(0, size.height - 40);
    path.quadraticBezierTo(
        size.width / 2, size.height + 40, size.width, size.height - 40);
    path.lineTo(size.width, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(CustomClipper) => false;
}

class Recommendation {
  final String currentInstance;
  final String newInstance;
  final String reason;
  final int vcpus;
  final double memoryGiB;
  final double hourlySavings;
  final String instanceId;
  final String name;

  Recommendation({
    required this.currentInstance,
    required this.newInstance,
    required this.reason,
    required this.vcpus,
    required this.memoryGiB,
    required this.hourlySavings,
    required this.instanceId,
    required this.name,
  });

  factory Recommendation.fromJson(Map<String, dynamic> json) => Recommendation(
        currentInstance: json['CurrentInstanceType'],
        newInstance: json['NewInstanceType'],
        reason: json['Reason'],
        vcpus: json['vCPUs'],
        memoryGiB: (json['MemoryGiB'] as num).toDouble(),
        hourlySavings: (json['HourlySavings'] as num).toDouble(),
        instanceId: json['instance_id'],
        name: json['name'],
      );

  Map<String, dynamic> toPayload() =>
      {'instance_id': instanceId, 'target_type': newInstance};
}
