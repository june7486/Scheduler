// 기간별 통계 화면.
//
// ## 왜 새 화면인가
// 리포트 화면(`report_screen.dart`)은 **인쇄용**입니다. A4 비율 미리보기,
// 사용자 선택, PDF 내보내기 — 마스터가 종이를 뽑기 위한 도구입니다.
// 그 화면에 "요일별로 몇 건 했나"를 넣으면 인쇄 미리보기가 스크롤 지옥이
// 되고, 정작 인쇄가 목적인 사람이 불편해집니다. 그래서 나눕니다.
//
// ## 계산은 여기서 하지 않는다
// 모든 숫자는 `services/stats.dart` 가 이미 계산해 둡니다. 이 파일은
// 그리기만 합니다. 그래야 "숫자가 맞는가"를 위젯 없이 시험할 수 있습니다.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/stats.dart';
import '../services/store.dart';
import '../theme/app_theme.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  StatsRange _range = StatsRange.month;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<Store>();
    final ko = store.language != 'en';

    // build() 안에서 매번 계산합니다. 항목이 수백 건이면 1ms 수준이라
    // 캐시를 두는 편이 오히려 "왜 숫자가 안 바뀌지" 문제를 만듭니다.
    final snap = store.statsFor(_range);

    return Scaffold(
      appBar: AppBar(
        title: Text(ko ? '통계' : 'Statistics'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Container(height: 0.5, color: p.line),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _rangeTabs(ko),
                const SizedBox(height: 14),
                _periodLine(store, snap, ko),
                const SizedBox(height: 14),
                _headline(snap, ko),
                const SizedBox(height: 18),
                if (snap.isEmpty)
                  _emptyCard(ko)
                else ...[
                  _barSection(snap, ko),
                  const SizedBox(height: 22),
                  _categorySection(snap, ko),
                ],
                const SizedBox(height: 26),
                _footnote(ko),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 기간 선택

  Widget _rangeTabs(bool ko) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.soft.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: [
          _tab(StatsRange.week, ko ? '일주일' : 'Week', ko),
          _tab(StatsRange.month, ko ? '한 달' : 'Month', ko),
          _tab(StatsRange.year, ko ? '1년' : 'Year', ko),
          _tab(StatsRange.all, ko ? '전체' : 'All', ko),
        ],
      ),
    );
  }

  Widget _tab(StatsRange r, String label, bool ko) {
    final on = _range == r;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _range = r),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: on ? p.card : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: on ? Border.all(color: p.line) : null,
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                color: on ? p.indigo : p.inkSoft,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 기간 설명 줄

  /// 사용자가 요청한 표현을 **그대로** 화면에 적습니다.
  ///
  /// "직전 30일" 같은 말은 정확하지만, 사용자는 "한 달 전 오늘부터"라고
  /// 생각합니다. 두 표현이 다르면 사용자는 자기가 고른 기간이 아닌 걸
  /// 보고 있다고 느낍니다.
  Widget _periodLine(Store store, StatsSnapshot snap, bool ko) {
    final f = DateFormat('yyyy.MM.dd');
    final String label;
    switch (_range) {
      case StatsRange.week:
        label = ko ? '일주일 전 오늘부터 오늘까지' : 'A week ago today, through today';
      case StatsRange.month:
        label = ko ? '한 달 전 오늘부터 오늘까지' : 'A month ago today, through today';
      case StatsRange.year:
        label = ko ? '1년 전 오늘부터 오늘까지' : 'A year ago today, through today';
      case StatsRange.all:
        label = ko ? '처음 기록부터 오늘까지 (끝 없음)' : 'From the first record, through today';
    }
    final span = '${f.format(snap.from)} — ${f.format(snap.to)}';

    final owner = store.isMaster && store.masterViewingAll
        ? (ko ? '모든 사용자' : 'All users')
        : store.currentUserId;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.event_note_outlined, size: 14, color: p.inkSoft),
        const SizedBox(width: 7),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: p.ink,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                '$span · $owner',
                style: TextStyle(fontSize: 10.5, color: p.inkSoft),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 큰 숫자

  Widget _headline(StatsSnapshot snap, bool ko) {
    final rate = snap.rate;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 완료율 — 이 화면의 결론
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ko ? '완료율' : 'Completion',
                    style: TextStyle(fontSize: 10.5, color: p.inkSoft),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // 자료가 없으면 0% 가 아니라 "—". 0% 는 "전부 못 했다"는
                    // 뜻이라 사실과 다릅니다.
                    rate == null ? '—' : '${(rate * 100).round()}%',
                    style: TextStyle(
                      fontSize: 27,
                      height: 1.05,
                      fontWeight: FontWeight.w800,
                      color: rate == null ? p.inkSoft : p.indigo,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: _miniStat(ko ? '전체' : 'Total', '${snap.total}', p.ink),
                ),
              ),
            ],
          ),
          if (rate != null) ...[
            const SizedBox(height: 11),
            // 얇은 진행 막대. 숫자만으로는 60%가 어느 정도인지 감이 안 옵니다.
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: rate,
                minHeight: 5,
                backgroundColor: p.tracker,
                valueColor: AlwaysStoppedAnimation<Color>(p.indigo),
              ),
            ),
          ],
          const SizedBox(height: 13),
          Container(height: 0.5, color: p.line),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _miniStat(ko ? '완료' : 'Done', '${snap.done}', p.teal),
              ),
              Expanded(
                child: _miniStat(ko ? '남음' : 'Open', '${snap.open}', p.ink),
              ),
              Expanded(
                // 기한 초과만 색을 다르게. 이 숫자가 0이 아니면 할 일이 있다는
                // 신호이고, 화면에서 유일하게 "나쁜 소식"입니다.
                child: _miniStat(
                  ko ? '기한 초과' : 'Overdue',
                  '${snap.overdue}',
                  snap.overdue > 0 ? p.danger : p.inkSoft,
                ),
              ),
            ],
          ),
          if (snap.amount != 0) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.payments_outlined, size: 13, color: p.inkSoft),
                const SizedBox(width: 6),
                Text(
                  ko ? '금액 합계' : 'Amount total',
                  style: TextStyle(fontSize: 10.5, color: p.inkSoft),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _money(snap.amount),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: p.ink,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: p.inkSoft)),
        const SizedBox(height: 1),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------- 막대

  Widget _barSection(StatsSnapshot snap, bool ko) {
    final maxTotal = snap.buckets.fold<int>(
      1,
      (a, b) => b.total > a ? b.total : a,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          ko ? '기간별 추이' : 'Over time',
          ko ? '막대 전체가 그 기간의 항목, 진한 부분이 끝난 항목'
              : 'Full bar: items in the period; filled part: done',
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: p.line),
          ),
          // 가로 스크롤: "전체"가 36칸이 되면 폰 폭에서 막대가 실처럼 됩니다.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final b in snap.buckets)
                  _bar(b, maxTotal, ko, snap.buckets.length),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // 막대를 눌러 숫자를 읽게 하는 대신, 가장 큰 칸을 한 줄로 적습니다.
        // 탭해서 툴팁을 띄우는 방식은 폰에서 "안 눌리는" 기능이 되기 쉽습니다.
        _peakLine(snap, ko),
      ],
    );
  }

  Widget _bar(StatsBucket b, int maxTotal, bool ko, int count) {
    // 칸이 적으면 넓게, 많으면 좁게. 7칸일 때와 36칸일 때 같은 폭을 쓰면
    // 둘 중 하나는 반드시 이상해집니다.
    final w = count <= 7 ? 40.0 : (count <= 12 ? 26.0 : 18.0);
    final h = maxTotal == 0 ? 0.0 : (b.total / maxTotal) * 92.0;
    final doneH = maxTotal == 0 ? 0.0 : (b.done / maxTotal) * 92.0;

    return SizedBox(
      width: w,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            b.total == 0 ? '' : '${b.total}',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: p.inkSoft,
            ),
          ),
          const SizedBox(height: 2),
          // 트랙 (연한 바탕) — 0인 칸도 "여기는 비었다"가 보여야 합니다.
          Container(
            height: 92,
            width: w - 12,
            alignment: Alignment.bottomCenter,
            decoration: BoxDecoration(
              color: p.tracker.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(
                  height: h,
                  width: w - 12,
                  decoration: BoxDecoration(
                    color: p.indigo.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                Container(
                  height: doneH,
                  width: w - 12,
                  decoration: BoxDecoration(
                    color: p.indigo,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            b.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 8.5, color: p.inkSoft, height: 1.2),
          ),
        ],
      ),
    );
  }

  Widget _peakLine(StatsSnapshot snap, bool ko) {
    StatsBucket? peak;
    for (final b in snap.buckets) {
      if (peak == null || b.total > peak.total) peak = b;
    }
    if (peak == null || peak.total == 0) return const SizedBox.shrink();
    return Text(
      ko
          ? '가장 많았던 때: ${peak.label} · ${peak.total}건 (완료 ${peak.done})'
          : 'Busiest: ${peak.label} · ${peak.total} items (${peak.done} done)',
      style: TextStyle(fontSize: 10.5, color: p.inkSoft),
    );
  }

  // ------------------------------------------------------------------ 분류 표

  Widget _categorySection(StatsSnapshot snap, bool ko) {
    final fmt = NumberFormat('#,##0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          ko ? '분류별' : 'By category',
          ko ? '많이 담긴 순. 0건인 분류는 표에서 뺐습니다'
              : 'Most used first. Categories with no items are omitted',
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: p.line),
          ),
          child: Column(
            children: [
              for (var i = 0; i < snap.categories.length; i++) ...[
                if (i > 0) Container(height: 0.5, color: p.line),
                _catRow(snap.categories[i], snap.amount, fmt, ko),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _catRow(
    StatsCategory c,
    double totalAmount,
    NumberFormat fmt,
    bool ko,
  ) {
    final rate = c.rate;
    final col = Color(c.colorValue);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: col.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              c.emoji.isEmpty ? '•' : c.emoji,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 3),
                // 분류별 진행 막대. 표에 숫자만 있으면 "어디가 밀렸나"를
                // 세로로 훑어야 알 수 있습니다.
                ClipRRect(
                  borderRadius: BorderRadius.circular(2.5),
                  child: LinearProgressIndicator(
                    value: rate ?? 0,
                    minHeight: 3.5,
                    backgroundColor: p.tracker,
                    valueColor: AlwaysStoppedAnimation<Color>(col),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 46,
            child: Text(
              '${c.total}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              rate == null ? '—' : '${(rate * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: p.inkSoft),
            ),
          ),
          if (c.amount != 0)
            SizedBox(
              width: 78,
              child: Text(
                fmt.format(c.amount),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 10.5, color: p.inkSoft),
              ),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------- 기타

  Widget _sectionTitle(String title, String sub) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: p.ink,
          ),
        ),
        const SizedBox(height: 2),
        Text(sub, style: TextStyle(fontSize: 10.5, color: p.inkSoft)),
      ],
    );
  }

  Widget _emptyCard(bool ko) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 18),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: p.line),
      ),
      child: Column(
        children: [
          Icon(Icons.insights_outlined, size: 30, color: p.inkSoft),
          const SizedBox(height: 10),
          Text(
            ko ? '이 기간에는 기록이 없습니다' : 'No records in this period',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            ko
                ? '기간을 넓히거나, 항목을 추가해 보세요'
                : 'Widen the period, or add some items',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: p.inkSoft, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 기간이 무엇을 뜻하는지, 숫자가 어디서 오는지.
  ///
  /// 이 화면의 숫자는 대개 리포트 화면과 함께 보게 됩니다. 두 화면이
  /// 어떻게 같은 날짜를 쓰는지 적어 두지 않으면, 숫자가 다를 때(예: 아직
  /// 동기화 전) 원인을 찾을 단서가 없습니다.
  Widget _footnote(bool ko) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 0.5, color: p.line),
        const SizedBox(height: 10),
        Text(
          ko
              ? '· 날짜는 마감일 → 반복 발생일 → 만든 날 순서로 정합니다\n'
                  '· 반복 항목(매월 25일 등)은 이번 달 발생일로 셉니다\n'
                  '· 완료율이 「—」이면 그 기간에 기록이 없다는 뜻입니다 (0%와 다릅니다)'
              : '· A date is due date → recurrence day → created date\n'
                  '· Recurring items count on this month\'s occurrence\n'
                  '· A rate of "—" means no records there (not 0%)',
          style: TextStyle(fontSize: 10, color: p.inkSoft, height: 1.75),
        ),
      ],
    );
  }

  /// 금액 표기. 원 단위가 기본이지만, 큰 수는 만원/억으로 줄입니다.
  ///
  /// 1,234,567,890 원은 읽는 데 시간이 걸립니다. 통계는 훑어보는 화면이라
  /// 자릿수를 세게 만들면 안 됩니다.
  String _money(double v) {
    final neg = v < 0;
    final a = v.abs();
    final String s;
    if (a >= 100000000) {
      s = '${(a / 100000000).toStringAsFixed(a >= 1000000000 ? 0 : 1)}억';
    } else if (a >= 10000) {
      s = '${(a / 10000).toStringAsFixed(0)}만';
    } else {
      s = NumberFormat('#,##0').format(a);
    }
    return neg ? '-$s' : s;
  }
}
