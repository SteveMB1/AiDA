// lib/scale_recommendation_dialog.dart
//
// Fully-balanced braces + compact volume toggle.
// Tested with:  Flutter 3.19  •  dart analyze → 0 errors / 0 warnings.

import 'dart:convert';
import 'dart:ui';

import 'package:advanced_ai_diagnostics/ui_elements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:lottie/lottie.dart';

import 'action_dialog.dart';
import 'main.dart';

const _LIMITS_BY_TYPE = {
  'gp3': {'max_size': 16384, 'max_iops': 16000, 'max_throughput': 1000},
  'gp2': {'max_size': 16384, 'max_iops': 16000, 'max_throughput': 250},
  'io1': {'max_size': 16384, 'max_iops': 64000, 'max_throughput': 1000},
  'io2': {'max_size': 16384, 'max_iops': 64000, 'max_throughput': 1000},
  'st1': {'max_size': 16384, 'max_iops': null, 'max_throughput': 500},
};

class FrostedGlass extends StatelessWidget {
  final Widget child;
  final double blur;
  final EdgeInsets padding;

  const FrostedGlass({
    super.key,
    required this.child,
    this.blur = 8,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            border: Border.all(color: Colors.white12),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Text Styles & Theme Extensions
// ─────────────────────────────────────────────────────────────────────────────
extension GlassTheme on ThemeData {
  TextStyle get glassHeading => const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Colors.tealAccent,
      );

  TextStyle get glassBody => const TextStyle(
        fontSize: 14,
        height: 1.6,
        color: Colors.white70,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Dialog
// ─────────────────────────────────────────────────────────────────────────────
class ScaleRecommendationDialog extends StatelessWidget {
  final String instanceId;
  final String instanceType;

  const ScaleRecommendationDialog({
    super.key,
    required this.instanceId,
    required this.instanceType,
  });

  static Future<void> show(
    BuildContext context, {
    required String instanceId,
    required String instanceType,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => ScaleRecommendationDialog(
        instanceId: instanceId,
        instanceType: instanceType,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: _ScaleRecommendationContent(
        instanceId: instanceId,
        instanceType: instanceType,
      ),
    );
  }
}

class _ScaleRecommendationContent extends StatefulWidget {
  final String instanceId;
  final String instanceType;

  const _ScaleRecommendationContent({
    required this.instanceId,
    required this.instanceType,
  });

  @override
  State<_ScaleRecommendationContent> createState() =>
      _ScaleRecommendationContentState();
}

class _ScaleRecommendationContentState
    extends State<_ScaleRecommendationContent> {
  bool loadingCurrent = true;
  bool loadingRec = true;
  Map<String, dynamic> cur = {};
  Map<String, dynamic> rec = {};
  var currentVolumes = [];
  double monthlySavings = 0;
  bool applyInstanceChange = true;
  final Map<String, bool> applyVolChange = {};

  @override
  void initState() {
    super.initState();
    _fetchCurrent();
    _fetchRecommendation();
  }

  Future<void> _fetchCurrent() async {
    try {
      final token =
          await const FlutterSecureStorage().read(key: 'access_token');
      final resp = await http.get(
        Uri.parse(
            '$urlEndPoint/instance/info/?instance_type=${widget.instanceType}&cloud_provider=aws'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
      );
      final d = jsonDecode(resp.body);
      setState(() {
        cur = {
          'Type': widget.instanceType,
          'vCPUs': d['vCPUs'],
          'Memory': "${d['MemoryGiB']} GiB",
          'GPU': d['GPUCount'],
          'Price/hr': "\$${d['PricePerHourUSD']}",
        };
        loadingCurrent = false;
      });
    } catch (e) {
      Navigator.pop(context);
      showGlassMorphicDialog(
        context: context,
        message: 'Failed to load current instance info: $e',
        type: DialogType.error,
      );
    }
  }

  Future<void> _fetchRecommendation() async {
    try {
      final token =
          await const FlutterSecureStorage().read(key: 'access_token');
      final resp = await http.get(
        Uri.parse(
            '$urlEndPoint/scale/recommendation/?instance_id=${widget.instanceId}'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      final d = json.decode(utf8.decode(resp.bodyBytes));
      setState(() {
        rec = {
          'Type': d['NewInstanceType'],
          'vCPUs': d['vCPUs'],
          'Memory': "${d['MemoryGiB']} GiB",
          'GPU': d['GPUCount'],
          'Price/hr': "\$${d['PricePerHourUSD']}",
          'Reason': d['Reason'],
        };
        monthlySavings = (d['MonthlySavings'] ?? 0).toDouble();
        if (d['EBSVolumes'] != null) {
          currentVolumes = d['EBSVolumes'];
          for (var v in currentVolumes) {
            final id = v['ebs_volume_id'] as String;
            applyVolChange[id] = true;
          }
        }
        loadingRec = false;
      });
    } catch (e) {
      Navigator.pop(context);
      showGlassMorphicDialog(
        context: context,
        message: 'Failed to load recommendation: $e',
        type: DialogType.error,
      );
    }
  }

  Future<void> _confirm() async {
    try {
      final token =
          await const FlutterSecureStorage().read(key: 'access_token');
      final resp = await http.post(
        Uri.parse('$urlEndPoint/scale/confirm/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'instance_id': widget.instanceId,
          'apply_instance_change': applyInstanceChange,
          'apply_volume_ids': applyVolChange.entries
              .where((e) => e.value)
              .map((e) => e.key)
              .toList(),
        }),
      );
      Navigator.pop(context);
      final detail = jsonDecode(resp.body)['detail'];
      showGlassMorphicDialog(
        context: context,
        message: detail,
        type: resp.statusCode == 200 ? DialogType.success : DialogType.error,
      );
    } catch (e) {
      Navigator.pop(context);
      showGlassMorphicDialog(
        context: context,
        message: e.toString(),
        type: DialogType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FrostedGlass(
      blur: 12,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context),
            const SizedBox(height: 24),
            _buildCurrentSection(context),
            const SizedBox(height: 24),
            loadingRec
                ? _buildThinkingPanel()
                : _buildRecommendationPanel(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) => Column(
        children: [
          const Icon(Icons.cloud, size: 48, color: Colors.cyanAccent),
          const SizedBox(height: 12),
          Text(
            'Scale Recommendation',
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(color: Colors.white.withOpacity(0.95)),
          ),
        ],
      );

  Widget _buildCurrentSection(BuildContext context) => Column(
        children: [
          Text('Your Current Instance', style: Theme.of(context).glassHeading),
          const SizedBox(height: 12),
          loadingCurrent
              ? const SizedBox(/* … */)
              : Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  alignment: WrapAlignment.center,
                  children: cur.entries
                      .map((e) => _MetricTile(
                            icon: _iconForLabel(e.key),
                            label: e.key,
                            value: e.value.toString(),
                          ))
                      .toList(), // <-- now List<Widget>
                ),
        ],
      );

  Widget _buildThinkingPanel() => Column(
        children: [
          Lottie.asset('assets/ai_robot.json', width: 80),
          const SizedBox(height: 12),
          const Text('Crunching the numbers… 💭',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          const LogoLinearProgressIndicator(),
        ],
      );

  Widget _buildRecommendationPanel(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('Recommendation',
            textAlign: TextAlign.center, style: Theme.of(context).glassHeading),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          alignment: WrapAlignment.center,
          children: [
            _MetricTile(
              icon: Icons.shield,
              label: 'Type',
              value: rec['Type'],
            ),
            ...['vCPUs', 'Memory', 'GPU', 'Price/hr'].map((k) {
              return AnimatedMetricCard(
                icon: _iconForLabel(k),
                label: k,
                current: cur[k].toString(),
                recommended: rec[k].toString(),
              );
            })
          ],
        ),
        const SizedBox(height: 16),
        AnimatedSavingsBadge(monthlySavings: monthlySavings),
        const SizedBox(height: 12),
        Text('Description of Change', style: Theme.of(context).glassHeading),
        const SizedBox(height: 12),
        Center(child: Text(rec['Reason'], style: Theme.of(context).glassBody)),
        const SizedBox(height: 16),
        SwitchListTile.adaptive(
          title:
              Text('Apply instance change', style: Theme.of(context).glassBody),
          activeColor: Colors.cyanAccent,
          value: applyInstanceChange,
          onChanged: (v) => setState(() => applyInstanceChange = v),
        ),
        const SizedBox(height: 16),
        if (currentVolumes.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('EBS Volumes', style: Theme.of(context).glassHeading),
          const SizedBox(height: 12),
          const _TriBarLegend(),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: _EbsVolumesGrid(
                currentVolumes: currentVolumes,
                applyVolChange: applyVolChange,
                onToggle: (id, v) => setState(() => applyVolChange[id] = v),
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white60)),
            ),
            const SizedBox(width: 20),
            ElevatedButton.icon(
              onPressed: _confirm,
              icon: const Icon(Icons.upgrade, size: 18),
              label: const Text('Apply Change'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                backgroundColor: Colors.pinkAccent,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  IconData _iconForLabel(String label) {
    switch (label) {
      case 'vCPUs':
        return Icons.memory;
      case 'Memory':
        return Icons.sd_storage;
      case 'GPU':
        return Icons.podcasts;
      case 'Price/hr':
        return Icons.attach_money;
      default:
        return Icons.shield;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated Metric Card
// ─────────────────────────────────────────────────────────────────────────────
class AnimatedMetricCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final String current;
  final String recommended;

  const AnimatedMetricCard({
    super.key,
    required this.icon,
    required this.label,
    required this.current,
    required this.recommended,
  });

  @override
  _AnimatedMetricCardState createState() => _AnimatedMetricCardState();
}

class _AnimatedMetricCardState extends State<AnimatedMetricCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      lowerBound: 0.0,
      upperBound: 0.05,
    )..addListener(() => setState(() {}));
    _scale = Tween(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _ctl, curve: Curves.easeOutBack),
    );
  }

  @override
  Widget build(BuildContext context) {
    final curNum =
        num.tryParse(widget.current.replaceAll(RegExp(r'[^\d.-]'), ''));
    final recNum =
        num.tryParse(widget.recommended.replaceAll(RegExp(r'[^\d.-]'), ''));
    final up = curNum != null && recNum != null && recNum > curNum;
    final accent = up ? Colors.orangeAccent : Colors.lightGreenAccent;

    return GestureDetector(
      onTapDown: (_) => _ctl.forward(),
      onTapUp: (_) => _ctl.reverse(),
      onTapCancel: () => _ctl.reverse(),
      child: Transform.scale(
        scale: _scale.value,
        child: Container(
          width: 130,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
            boxShadow: [
              BoxShadow(
                  color: accent.withOpacity(0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 4)),
            ],
          ),
          child: Column(
            children: [
              Icon(widget.icon, size: 24, color: Colors.white70),
              const SizedBox(height: 8),
              Text(widget.label,
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(height: 8),
              FittedBox(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.current,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 14)),
                    const SizedBox(width: 4),
                    Icon(up ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 16, color: accent),
                    const SizedBox(width: 4),
                    Text(widget.recommended,
                        style: TextStyle(
                            color: accent, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Animated Savings Badge
// ─────────────────────────────────────────────────────────────────────────────
class AnimatedSavingsBadge extends StatelessWidget {
  final double monthlySavings;

  const AnimatedSavingsBadge({super.key, required this.monthlySavings});

  @override
  Widget build(BuildContext context) {
    final isPositive = monthlySavings >= 0;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      transitionBuilder: (child, anim) =>
          ScaleTransition(scale: anim, child: child),
      child: Container(
        key: ValueKey<double>(monthlySavings),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isPositive
                ? [Colors.lightGreenAccent, Colors.greenAccent.shade400]
                : [Colors.orangeAccent.shade200, Colors.deepOrangeAccent],
          ),
          borderRadius: BorderRadius.circular(40),
          boxShadow: [
            BoxShadow(
                color: (isPositive ? Colors.green : Colors.deepOrange)
                    .withOpacity(.5),
                blurRadius: 10,
                offset: const Offset(0, 4))
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        child: Text(
          isPositive
              ? 'Save \$${monthlySavings.toStringAsFixed(2)}/mo'
              : 'Costs \$${(-monthlySavings).toStringAsFixed(2)}/mo',
          style: const TextStyle(
              color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 15),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: Colors.white70),
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
          const SizedBox(height: 8),
          Text(value,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
        ],
      ),
    );
  }
}

class _EbsVolumesGrid extends StatelessWidget {
  /// Now a List of JSON objects
  final List currentVolumes;
  final Map<String, bool> applyVolChange;
  final void Function(String id, bool value) onToggle;

  const _EbsVolumesGrid({
    required this.currentVolumes,
    required this.applyVolChange,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    num? safe(num? n) => (n == null || n == 0) ? null : n;

    return Wrap(
      spacing: 16,
      runSpacing: 16,
      alignment: WrapAlignment.center,
      children: currentVolumes.map((cur) {
        // extract id from each map
        final id = cur['ebs_volume_id'] as String;
        final mountPoint = cur['mount_point_name'] as String? ?? '-';

        // volume‑type defaults (if you have a map for gp3, io2, etc.)
        final volType =
            (cur['CurrentVolumeType'] as String? ?? '').toLowerCase();
        final limits = {
          'size': _LIMITS_BY_TYPE[volType]?['max_size'],
          'iops': _LIMITS_BY_TYPE[volType]?['max_iops'],
          'throughput': _LIMITS_BY_TYPE[volType]?['max_throughput'],
        };

        return _EbsVolumeCard(
          id: id,
          mountPoint: mountPoint,
          volumeType: cur['CurrentVolumeType'] ?? '?',
          // current metrics
          sizeCur: safe(cur['CurrentSizeGB'] as num?),
          iopsCur: safe(cur['CurrentIops'] as num?),
          tpCur: safe(cur['CurrentThroughput'] as num?),
          // recommended metrics
          sizeRec: safe(cur['size'] as num?),
          iopsRec: safe(cur['iops'] as num?),
          tpRec: safe(cur['throughput'] as num?),
          // limits
          sizeMax: limits['size'] as num?,
          iopsMax: limits['iops'] as num?,
          tpMax: limits['throughput'] as num?,
          // toggle
          enabled: applyVolChange[id] ?? true,
          onToggle: (v) => onToggle(id, v),
        );
      }).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Single Volume Card
// ─────────────────────────────────────────────────────────────────────────────
class _EbsVolumeCard extends StatelessWidget {
  const _EbsVolumeCard({
    required this.id,
    required this.mountPoint,
    required this.volumeType,
    required this.sizeCur,
    required this.iopsCur,
    required this.tpCur,
    this.sizeRec,
    this.iopsRec,
    this.tpRec,
    required this.sizeMax,
    required this.iopsMax,
    required this.tpMax,
    required this.enabled,
    required this.onToggle,
  });

  final String id, mountPoint, volumeType;
  final num? sizeCur, iopsCur, tpCur;
  final num? sizeRec, iopsRec, tpRec;
  final num? sizeMax, iopsMax, tpMax;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    // Pick one of three gradients based on hash so colors vary per-card
    final grad = [
      [const Color(0xFF00BCD4), const Color(0xFF0D47A1)],
      [const Color(0xFFFF8A65), const Color(0xFFD84315)],
      [const Color(0xFFAB47BC), const Color(0xFF4A148C)],
    ][id.hashCode % 3];

    return Container(
      width: 250,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: grad.map((c) => c.withOpacity(0.9)).toList(),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: grad.last.withOpacity(0.4),
            blurRadius: 12,
            offset: const Offset(0, 6),
          )
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header row + compact toggle
        Row(children: [
          const Icon(Icons.storage, color: Colors.white, size: 18),
          const SizedBox(width: 6),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                id,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                mountPoint,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontStyle: FontStyle.italic),
              ),
            ],
          )),
          Transform.scale(
            scale: 0.7,
            child: Switch.adaptive(
              value: enabled,
              activeColor: Colors.cyanAccent,
              onChanged: onToggle,
            ),
          ),
        ]),
        const SizedBox(height: 10),

        // Volume type badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.25),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            volumeType.toUpperCase(),
            style: const TextStyle(
                color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 12),

        if (sizeCur != null && sizeMax != null) ...[
          _TriBar(
              label: 'Size',
              cur: sizeCur!,
              rec: sizeRec,
              max: sizeMax!,
              unit: ' GiB'),
          const SizedBox(height: 10),
        ],
        if (iopsCur != null && iopsMax != null) ...[
          _TriBar(label: 'IOPS', cur: iopsCur!, rec: iopsRec, max: iopsMax!),
          const SizedBox(height: 10),
        ],
        if (tpCur != null && tpMax != null)
          _TriBar(
              label: 'Throughput',
              cur: tpCur!,
              rec: tpRec,
              max: tpMax!,
              unit: ' MB/s'),
      ]),
    );
  }
}
// ────────────────────────  TRI-BAR + LEGEND  ───────────────────────────

class _TriBar extends StatelessWidget {
  const _TriBar({
    required this.label,
    required this.cur,
    required this.max,
    this.rec,
    this.unit,
  });

  final String label;
  final num cur, max;
  final num? rec;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final curPct = (cur / max).clamp(0, 1).toDouble();
    final recVal = rec ?? cur;
    final recPct = (recVal / max).clamp(0, 1).toDouble();

    final downsizing = rec != null && recVal < cur;
    final diffPct = (curPct - recPct).abs();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ${cur.toStringAsFixed(0)}'
          '${unit ?? ''} / '
          '${rec?.toStringAsFixed(0) ?? '--'} / '
          '${max.toStringAsFixed(0)}${unit ?? ''}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 4),
        LayoutBuilder(builder: (_, cons) {
          const minSlice = 2.0;
          final double w = cons.maxWidth;

          // initial slice widths
          double wMain = w * (downsizing ? recPct : curPct);
          double wDelta = w * diffPct;

          // if main is tiny, bump it up and steal space from delta
          if (wMain > 0 && wMain < minSlice) {
            final deficit = minSlice - wMain;
            wMain = minSlice;
            wDelta = (wDelta - deficit).clamp(0.0, w).toDouble();
          }

          // if delta is tiny, bump it up and steal space from main
          if (wDelta > 0 && wDelta < minSlice) {
            final deficit = minSlice - wDelta;
            wDelta = minSlice;
            wMain = (wMain - deficit).clamp(0.0, w).toDouble();
          }

          // now compute head‑room as exact leftover (no rounding drift)
          final double wHead = (w - wMain - wDelta).clamp(0.0, w).toDouble();

          final deltaColor =
              downsizing ? Colors.lightGreenAccent : Colors.amberAccent;

          Widget slice(double width, Color color) => Container(
                width: width,
                height: 6,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                ),
              );

          return Row(
            children: [
              if (wMain > 0) slice(wMain, Colors.cyanAccent),
              if (wDelta > 0) slice(wDelta, deltaColor),
              if (wHead > 0) slice(wHead, Colors.white24),
            ],
          );
        }),
      ],
    );
  }
}

class _TriBarLegend extends StatelessWidget {
  const _TriBarLegend();

  @override
  Widget build(BuildContext context) {
    Widget chip(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 6,
              decoration: BoxDecoration(
                color: c,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(color: Colors.white60, fontSize: 11)),
          ],
        );

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 8,
      children: [
        chip(Colors.cyanAccent, 'Current'),
        chip(Colors.amberAccent, 'Increase'),
        chip(Colors.lightGreenAccent, 'Decrease'),
        chip(Colors.white24, 'Head-room'),
      ],
    );
  }
}
