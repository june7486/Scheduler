// 어두운 화면에서 글자가 배경에 묻히던 버그의 회귀 테스트.
//
// ## 무엇이 잘못됐었나
// `p`(팔레트)는 전역 밝기 값으로 색을 고르는데, 그 값은 원래
// `MaterialApp.builder` 안에서만 갱신됐다. 그런데 builder 는 자기가 감싸는
// 위젯들이 **이미 빌드된 뒤** 실행된다. 그래서 첫 프레임은
//
//   ThemeData → dark   (MaterialApp 은 store 를 보고 판단)
//   p         → light  (전역은 아직 갱신 전)
//
// 이라는 모순 상태가 됐고, 그 결과 카드/사이드바는 순백인데 스캐폴드는
// 새까맣고, 본문 글자는 어두운 배경 위의 어두운 글자가 됐다.
// 이 테스트는 "두 답이 같아야 한다"는 것만 확인한다.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:june_scheduler/theme/app_theme.dart';

/// WCAG 상대 휘도.
double _lum(Color c) {
  double lin(double v) {
    v = v / 255.0;
    return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin(c.r * 255) + 0.7152 * lin(c.g * 255) + 0.0722 * lin(c.b * 255);
}

double _contrast(Color a, Color b) {
  final la = _lum(a);
  final lb = _lum(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('어두운 화면 대비 — 팔레트가 스스로 무너지지 않는가', () {
    test('모든 스킨에서 본문 글자가 카드 배경에 대해 읽힌다 (WCAG AA 4.5:1)', () {
      for (final id in AppSkins.ids) {
        for (final b in [Brightness.light, Brightness.dark]) {
          final pal = AppSkins.forId(id, b);
          final ratio = _contrast(pal.ink, pal.card);
          expect(
            ratio,
            greaterThan(4.5),
            reason: '$id / $b: ink 대 card 대비가 ${ratio.toStringAsFixed(2)}:1 밖에 안 된다. '
                '이게 바로 글자가 묻히는 상태다.',
          );
        }
      }
    });

    test('보조 글자(inkSoft)도 배경 위에서 최소한 읽을 수 있다 (3:1)', () {
      for (final id in AppSkins.ids) {
        for (final b in [Brightness.light, Brightness.dark]) {
          final pal = AppSkins.forId(id, b);
          expect(
            _contrast(pal.inkSoft, pal.card),
            greaterThan(3.0),
            reason: '$id / $b: 보조 글자가 너무 흐리다',
          );
          expect(
            _contrast(pal.inkSoft, pal.bg),
            greaterThan(2.6),
            reason: '$id / $b: 배경 위 보조 글자가 너무 흐리다',
          );
        }
      }
    });

    test('어두운 팔레트는 실제로 어둡고, 밝은 팔레트는 실제로 밝다', () {
      for (final id in AppSkins.ids) {
        final dark = AppSkins.forId(id, Brightness.dark);
        final light = AppSkins.forId(id, Brightness.light);
        expect(_lum(dark.bg), lessThan(0.12),
            reason: '$id: 어두운 팔레트의 bg 가 어둡지 않다 — 이름만 dark 다');
        expect(_lum(dark.card), lessThan(0.20),
            reason: '$id: 어두운 팔레트의 card 가 어둡지 않다. '
                '이 값이 밝으면 다크모드에서 흰 패널이 튀어나온다.');
        expect(_lum(light.bg), greaterThan(0.55),
            reason: '$id: 밝은 팔레트의 bg 가 밝지 않다');
        // 어두운 카드가 밝은 카드보다 반드시 어두워야 한다.
        expect(_lum(dark.card), lessThan(_lum(light.card)),
            reason: '$id: dark.card 가 light.card 보다 어둡지 않다');
      }
    });

    test('밝기 전환 자체가 팔레트를 실제로 바꾼다 (전역 setter 가 먹는가)', () {
      setSkin('midnight');
      setGlobalBrightness(Brightness.light);
      final lightCard = p.card;
      final lightInk = p.ink;

      setGlobalBrightness(Brightness.dark);
      final darkCard = p.card;
      final darkInk = p.ink;

      expect(darkCard, isNot(lightCard),
          reason: 'setGlobalBrightness 를 불러도 p 가 그대로다 — '
              '이게 다크모드가 절반만 적용되던 원인이다');
      expect(darkInk, isNot(lightInk));
      expect(_lum(darkCard), lessThan(_lum(lightCard)));
      // 어두운 모드에서 글자는 반드시 밝아져야 한다.
      expect(_lum(darkInk), greaterThan(_lum(lightInk)),
          reason: '어두운 배경인데 글자도 어두워지면 아무것도 안 보인다');

      setGlobalBrightness(Brightness.light);
    });

    test('기본(default) 스킨이 어두운 화면에서 흰 카드를 내놓지 않는다', () {
      // 사용자가 본 증상 그대로: 사이드바/칩 줄만 순백이었다.
      setGlobalBrightness(Brightness.dark);
      final pal = AppSkins.forId(AppSkins.defaultId, Brightness.dark);
      expect(_lum(pal.card), lessThan(0.20),
          reason: '어두운 모드인데 카드가 희다 — 화면의 절반만 어두워진다');
      expect(_contrast(pal.ink, pal.card), greaterThan(4.5));
      setGlobalBrightness(Brightness.light);
    });
  });
}
