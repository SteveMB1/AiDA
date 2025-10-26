// lib/aggregate_dashboard_page.dart  – v3.3 (auto-refresh • % doughnut • nicer axes)
import 'dart:math';
import 'dart:ui';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'monitoring_status.dart' show Record, FailingState;

/// ⬇️  MAIN PAGE  ────────────────────────────────────────────────────
class AggregateDashboardPage extends StatefulWidget {
  final List<Record> allRecords;

  const AggregateDashboardPage({super.key, required this.allRecords});

  @override
  State<AggregateDashboardPage> createState() => _AggregateDashboardPageState();
}

class _AggregateDashboardPageState extends State<AggregateDashboardPage>
    with TickerProviderStateMixin {
  // current filter
  late String _env, _proj;

  // tabs in trend panel
  late TabController _trendTabs;

  // easy access
  List<Record> get _recs => widget.allRecords.where((r) {
        return (r.tags['Environment'] as String) == _env &&
            (r.tags['Project'] as String) == _proj;
      }).toList();

  // avg / sum helpers
  double _avg(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;

  double _sum(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b);

  @override
  void initState() {
    super.initState();
    _env = widget.allRecords
        .map((r) => r.tags['Environment'] as String)
        .toSet()
        .first;
    _proj = widget.allRecords
        .where((r) => (r.tags['Environment'] as String) == _env)
        .map((r) => r.tags['Project'] as String)
        .first;
    _trendTabs = TabController(length: 6, vsync: this);
  }

  //  🔄  AUTO-REFRESH when parent supplies new records  -------------
  @override
  void didUpdateWidget(covariant AggregateDashboardPage old) {
    super.didUpdateWidget(old);
    if (old.allRecords != widget.allRecords) setState(() {});
  }

  // cloud-watch helper
  List<double> _cw(String key) => _recs
      .expand((r) => r.cloudwatch[key] ?? [])
      .map<double>((p) => p.value)
      .toList();

  // format helper for axes / tooltips
  String _fmtNum(double v, {String unit = ''}) {
    if (v.isNaN) return '–';
    if (unit == '%') return '${v.toStringAsFixed(0)}%';
    if (unit == 'ms') return '${v.toStringAsFixed(0)}ms';
    if (v >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}G$unit';
    if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M$unit';
    if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K$unit';
    return '${v.toStringAsFixed(1)}$unit';
  }

  /// Line-chart with 15 % head / foot margin so the first and last grid
  /// lines never touch the rounded card border.
  Widget _trend(List<double> vals, {String unit = ''}) {
    if (vals.isEmpty) {
      return const Center(
        child: Text('No data',
            style: TextStyle(color: Colors.white54, fontSize: 13)),
      );
    }

    // build spots
    final spots =
        List.generate(vals.length, (i) => FlSpot(i.toDouble(), vals[i]));

    // dynamic range + 15 % padding
    var minY = vals.reduce(min);
    var maxY = vals.reduce(max);
    final range = max(maxY - minY, 1); // guard zero range
    final pad = range * 0.15;
    minY = (minY - pad).clamp(0, double.infinity);
    maxY = maxY + pad;

    final double interval = range / 4; // axis tick spacing

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12), // extra outer space
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              barWidth: 2,
              isCurved: true,
              color: Colors.cyanAccent,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  colors: [
                    Colors.cyanAccent.withOpacity(.25),
                    Colors.transparent
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            )
          ],
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: interval,
                reservedSize: 42,
                getTitlesWidget: (v, _) => Text(
                  _fmtNum(v, unit: unit),
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                ),
              ),
            ),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
        ),
      ),
    );
  }

  // RAM trend across timestamps
  List<double> _ramTrend() {
    final maxLen =
        _recs.map((r) => r.rams.length).fold<int>(0, (p, e) => max(p, e));
    return List<double>.generate(maxLen, (i) {
      final vals = <double>[];
      for (final r in _recs) {
        if (i < r.rams.length) vals.add(r.rams[i].percentage);
      }
      return _avg(vals);
    });
  }

  // Mongo replication-lag trend
  List<double> _mongoTrend() {
    final map = <int, List<double>>{};
    for (final r in _recs) {
      for (var i = 0; i < r.checks.length; i++) {
        map
            .putIfAbsent(i, () => [])
            .add(r.checks[i].replicationLagMs.toDouble());
      }
    }
    final keys = map.keys.toList()..sort();
    return keys.map((k) => _avg(map[k]!)).toList();
  }

  @override
  Widget build(BuildContext context) {
    // ── KPI data ---------------------------------------------------
    final ramPct =
        _recs.expand((r) => r.rams).map<double>((x) => x.percentage).toList();
    final cpu = _cw('cpu');
    final netIn = _cw('network_in');
    final netOut = _cw('network_out');
    final diskPct = _recs
        .expand((r) => r.partitions)
        .map<double>((p) => p.percent)
        .toList();
    final mongoLag = _recs
        .expand((r) => r.checks)
        .map<double>((c) => c.replicationLagMs.toDouble())
        .toList();
    final gpuUtil = _recs
        .expand((r) => r.tasks)
        .expand((b) => b)
        .where((t) => t['nvidia'] != null)
        .map<double>(
            (t) => (t['nvidia']['average_utilization'] as num).toDouble())
        .toList();
    final rabbitCnt = _recs.expand((r) => r.rabbitQueues).length.toDouble();

    final kpiTiles = [
      Tile(
          label: 'Avg RAM',
          value: _avg(ramPct),
          suffix: '%',
          series: ramPct,
          spark: _sparkMini(ramPct)),
      Tile(
          label: 'Avg CPU',
          value: _avg(cpu),
          suffix: '%',
          series: cpu,
          spark: _sparkMini(cpu)),
      Tile(
          label: 'Net In',
          value: _sum(netIn) / 1e6,
          suffix: ' MB',
          series: netIn,
          spark: _sparkMini(netIn)),
      Tile(
          label: 'Net Out',
          value: _sum(netOut) / 1e6,
          suffix: ' MB',
          series: netOut,
          spark: _sparkMini(netOut)),
      Tile(
          label: 'Mongo Lag',
          value: _avg(mongoLag),
          suffix: ' ms',
          series: mongoLag,
          spark: _sparkMini(mongoLag)),
      Tile(
          label: 'Peak Disk',
          value: diskPct.isEmpty ? 0 : diskPct.reduce(max),
          suffix: '%',
          series: diskPct,
          spark: _sparkMini(diskPct)),
      Tile(
          label: 'GPU Util',
          value: _avg(gpuUtil),
          suffix: '%',
          series: gpuUtil,
          spark: _sparkMini(gpuUtil)),
      Tile(
          label: 'Rabbit Qs',
          value: rabbitCnt,
          suffix: '',
          series: const [],
          spark: const SizedBox(height: 30)),
    ];

    // ── partition doughnut with % labels --------------------------
    final partGroups = <String, List<double>>{};
    for (final p in _recs.expand((r) => r.partitions)) {
      partGroups.putIfAbsent(p.partition, () => []).add(p.percent);
    }
    String tapped = '';
    final totalPct =
        partGroups.values.expand((l) => l).fold<double>(0, (a, b) => a + b);
    final pieSections =
        List<PieChartSectionData>.generate(partGroups.length, (i) {
      final mount = partGroups.keys.elementAt(i);
      final pct = _avg(partGroups[mount]!);
      return PieChartSectionData(
        value: pct,
        title: '$mount\n${pct.toStringAsFixed(1)}%',
        titleStyle: const TextStyle(color: Colors.white, fontSize: 10),
        radius: tapped == mount ? 58 : 48,
      );
    });
    final doughnut = StatefulBuilder(builder: (ctx, setSt) {
      return Card(
          color: Colors.black54,
          child: SizedBox(
              height: 200,
              child: PieChart(
                PieChartData(
                    sections: pieSections,
                    centerSpaceRadius: 40,
                    pieTouchData: PieTouchData(touchCallback: (ev, resp) {
                      if (resp?.touchedSection == null || ev is! FlTapUpEvent) {
                        return;
                      }
                      final idx = resp!.touchedSection!.touchedSectionIndex;
                      setSt(() => tapped =
                          partGroups.keys.elementAt(idx) == tapped
                              ? ''
                              : partGroups.keys.elementAt(idx));
                    })),
              )));
    });

    // ── issues list ----------------------------------------------
    final issues = <_IssueEntry>[];
    for (final r in _recs) {
      // scan each record's flat list of timestamped failures
      for (final fs in r.failingStateRecords) {
        if (fs.result) {
          issues.add(_IssueEntry(
            server: r.name,
            service: fs.service,
            metric: fs.metric,
            description: fs.description,
            detail: fs.detail,
          ));
        }
      }
    }
    issues.sort((a, b) => a.service.compareTo(b.service));
    final issuesPanel = Card(
      color: Colors.black54,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: issues.isEmpty
            ? const Text('No issues',
                style: TextStyle(color: Colors.greenAccent))
            : Column(children: issues.map((e) => e.build(context)).toList()),
      ),
    );

    // ── trend tabs ------------------------------------------------
    final trendCard = Card(
        color: Colors.black54,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          TabBar(
              controller: _trendTabs,
              labelColor: Colors.cyanAccent,
              unselectedLabelColor: Colors.white70,
              tabs: const [
                Tab(text: 'CPU'),
                Tab(text: 'RAM'),
                Tab(text: 'Net In'),
                Tab(text: 'Net Out'),
                Tab(text: 'Disk'),
                Tab(text: 'Mongo')
              ]),
          SizedBox(
            height: 240,
            child: TabBarView(controller: _trendTabs, children: [
              _trend(cpu, unit: '%'),
              _trend(_ramTrend(), unit: '%'),
              _trend(netIn, unit: 'B'),
              _trend(netOut, unit: 'B'),
              _trend(_cw('network_total_pct'), unit: '%'),
              _trend(_mongoTrend(), unit: 'ms'),
            ]),
          )
        ]));

    // ── pivot table (same as v3.2, omitted for brevity) -----------
    final cwKeys = _recs.expand((r) => r.cloudwatch.keys).toSet().toList()
      ..sort();
    String selMetric = cwKeys.isNotEmpty ? cwKeys.first : '';
    final pivot = StatefulBuilder(builder: (ctx, setSt) {
      final byProg = <String, List<Record>>{};
      for (final r in _recs) {
        byProg.putIfAbsent(r.program, () => []).add(r);
      }
      final rows = byProg.entries.map((e) {
        final vals = e.value
            .expand((r) => r.cloudwatch[selMetric] ?? [])
            .map<double>((p) => p.value)
            .toList();
        return DataRow(cells: [
          DataCell(Text(e.key)),
          DataCell(Text(vals.isEmpty ? '—' : _fmtNum(_avg(vals)))),
          DataCell(Text(vals.isEmpty ? '—' : _fmtNum(vals.reduce(min)))),
          DataCell(Text(vals.isEmpty ? '—' : _fmtNum(vals.reduce(max)))),
        ]);
      }).toList();
      return Column(children: [
        DropdownButton<String>(
            value: selMetric,
            items: cwKeys
                .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                .toList(),
            onChanged: (v) => setSt(() => selMetric = v ?? selMetric)),
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
                columns: const [
                  DataColumn(label: Text('Program')),
                  DataColumn(label: Text('Avg')),
                  DataColumn(label: Text('Min')),
                  DataColumn(label: Text('Max'))
                ],
                rows: rows,
                headingRowColor: WidgetStateProperty.all(Colors.white10),
                dataRowColor: WidgetStateProperty.all(Colors.white12),
                headingTextStyle: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
                dataTextStyle: const TextStyle(color: Colors.white70)))
      ]);
    });

    // ── filters ---------------------------------------------------
    Widget drop(String label, String val, List<String> items,
            ValueChanged<String?> cb) =>
        DropdownButtonFormField<String>(
            decoration: InputDecoration(labelText: label),
            value: val,
            items: (items..sort())
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: cb);

    final filterBar = Row(children: [
      Expanded(
          child: drop(
              'Environment',
              _env,
              widget.allRecords
                  .map((r) => r.tags['Environment'] as String)
                  .toSet()
                  .toList(), (v) {
        if (v != null) {
          setState(() => _env = v);
        }
      })),
      const SizedBox(width: 16),
      Expanded(
          child: drop(
              'Project',
              _proj,
              widget.allRecords
                  .where((r) => (r.tags['Environment'] as String) == _env)
                  .map((r) => r.tags['Project'] as String)
                  .toSet()
                  .toList(),
              (v) => setState(() => _proj = v ?? _proj))),
    ]);

    // ── scaffold --------------------------------------------------
    return Scaffold(
        backgroundColor: const Color(0xFF101012),
        appBar: AppBar(
            title: const Text('Aggregate Dashboard'),
            backgroundColor: Colors.black87),
        body: Stack(children: [
          Positioned.fill(
              child: Image.asset('assets/background.jpg', fit: BoxFit.cover)),
          Positioned.fill(
              child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                  child: Container(color: Colors.black.withOpacity(.3)))),
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  filterBar,
                  const SizedBox(height: 24),
                  Wrap(spacing: 16, runSpacing: 16, children: kpiTiles),
                  const SizedBox(height: 24),
                  trendCard,
                  const SizedBox(height: 24),
                  doughnut,
                  const SizedBox(height: 24),
                  issuesPanel,
                  const SizedBox(height: 24),
                  pivot,
                ]),
          ),
        ]));
  }
}

/// ╰─ Issue entry UI ───────────────────────────────────────────────
class _IssueEntry {
  final String server, service, metric, description, detail;

  _IssueEntry(
      {required this.server,
      required this.service,
      required this.metric,
      required this.description,
      required this.detail});

  Widget build(BuildContext ctx) => ExpansionTile(
          leading: const Icon(Icons.warning, color: Colors.redAccent),
          title: Text('$service → $metric',
              style: const TextStyle(color: Colors.redAccent, fontSize: 14)),
          subtitle: Text(server, style: const TextStyle(color: Colors.white70)),
          children: [
            Padding(
                padding: const EdgeInsets.all(8),
                child: SelectableText(detail,
                    style: const TextStyle(color: Colors.white70)))
          ]);
}

/// ╰─ KPI tile with sparkline  ─────────────────────────────────────
class Tile extends StatelessWidget {
  final String label;
  final double value;
  final String suffix;
  final List<double> series;
  final Widget spark;

  const Tile(
      {super.key,
      required this.label,
      required this.value,
      required this.suffix,
      required this.series,
      required this.spark});

  @override
  Widget build(BuildContext context) {
    final vStr =
        value.isNaN ? '—' : value.toStringAsFixed(value > 1000 ? 0 : 1);
    return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
                width: 155,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24, width: 1),
                    gradient: LinearGradient(colors: [
                      Colors.white.withOpacity(.08),
                      Colors.white.withOpacity(.02)
                    ], begin: Alignment.topLeft, end: Alignment.bottomRight)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 6),
                      Text('$vStr$suffix',
                          style: const TextStyle(
                              color: Colors.cyanAccent,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                      spark,
                    ]))));
  }
}

Widget _sparkMini(List<double> v) {
  if (v.length <= 1) return const SizedBox(height: 30);
  final spots = List.generate(v.length, (i) => FlSpot(i.toDouble(), v[i]));
  return SizedBox(
    height: 30,
    child: LineChart(
      LineChartData(
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
        ],
      ),
    ),
  );
}
