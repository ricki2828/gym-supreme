import 'dart:convert';

import 'package:gym_engine/src/cut2/rotation.dart';
import 'package:test/test.dart';

void main() {
  final ppl = Rotation(['push', 'pull', 'legs']);

  test('defaults: push, pull, legs; push next', () {
    final r = Rotation.defaults();
    expect(r.order, ['push', 'pull', 'legs']);
    expect(r.nextId, 'push');
    expect(r.upcoming, ['push', 'pull', 'legs']);
  });

  test('next is resolved before empties and duplicates are dropped', () {
    expect(Rotation(['push', '', 'pull'], next: 2).nextId, 'pull');
    expect(Rotation(['push', 'push', 'legs'], next: 2).nextId, 'legs');
    expect(Rotation(['push', 'push', 'legs'], next: 1).nextId, 'push');
  });

  test('normalises duplicates, empties and next out of range', () {
    final r = Rotation(['push', '', 'pull', 'push'], next: 5);
    expect(r.order, ['push', 'pull']);
    expect(r.next, 1);
    expect(Rotation(['a', 'b', 'c'], next: -1).nextId, 'c');
    expect(Rotation(const []).nextId, isNull);
    expect(Rotation(const []).upcoming, isEmpty);
  });

  group('completed', () {
    test('the suggested one advances by one, wrapping', () {
      expect(ppl.completed('push').nextId, 'pull');
      expect(
        ppl.completed('push').completed('pull').completed('legs').nextId,
        'push',
      );
    });

    test('a different type moves the pointer past what he did', () {
      expect(ppl.completed('legs').nextId, 'push');
      expect(ppl.completed('pull').nextId, 'legs');
    });

    test('a type outside the rotation or a mixed pick changes nothing', () {
      expect(ppl.completed('core'), ppl);
      expect(ppl.completed(null), ppl);
      expect(Rotation(const []).completed('push').nextId, isNull);
    });
  });

  test('skip advances without training; upcoming starts at next', () {
    final r = ppl.skip();
    expect(r.nextId, 'pull');
    expect(r.upcoming, ['pull', 'legs', 'push']);
    expect(Rotation(const []).skip().isEmpty, isTrue);
  });

  group('move (drag)', () {
    test('the suggested type stays suggested', () {
      final r = ppl.skip(); // pull next
      final m = r.move(1, 0); // pull to the top
      expect(m.order, ['pull', 'push', 'legs']);
      expect(m.nextId, 'pull');
      final m2 = r.move(0, 2); // push to the end
      expect(m2.order, ['pull', 'legs', 'push']);
      expect(m2.nextId, 'pull');
    });

    test('onReorder takes Flutter indices (drag to the end)', () {
      final m = ppl.onReorder(0, 3); // push dragged below legs
      expect(m.order, ['pull', 'legs', 'push']);
      expect(m.nextId, 'push');
      expect(ppl.onReorder(2, 0).order, ['legs', 'push', 'pull']);
    });

    test('same index is a no-op; out of range throws', () {
      expect(ppl.move(1, 1), ppl);
      expect(() => ppl.move(3, 0), throwsRangeError);
      expect(() => ppl.move(0, -1), throwsRangeError);
    });
  });

  test('pointAt', () {
    expect(ppl.pointAt('legs').nextId, 'legs');
    expect(() => ppl.pointAt('core'), throwsArgumentError);
  });

  group('add / remove', () {
    test('add appends once', () {
      final r = ppl.add('core');
      expect(r.order, ['push', 'pull', 'legs', 'core']);
      expect(r.nextId, 'push');
      expect(r.add('core'), r);
      expect(r.add(''), r);
    });

    test('removing the suggested one suggests the one after it', () {
      final r = ppl.skip().remove('pull'); // pull was next
      expect(r.order, ['push', 'legs']);
      expect(r.nextId, 'legs');
      final wrap = ppl.pointAt('legs').remove('legs');
      expect(wrap.nextId, 'push');
    });

    test('removing another keeps the suggestion', () {
      final r = ppl.pointAt('legs').remove('push');
      expect(r.order, ['pull', 'legs']);
      expect(r.nextId, 'legs');
    });

    test('removing the last one empties; missing id is a no-op', () {
      expect(Rotation(['push']).remove('push').isEmpty, isTrue);
      expect(ppl.remove('core'), ppl);
    });

    test('retainOnly with no known types keeps the rotation', () {
      expect(ppl.retainOnly(const {}), ppl);
    });

    test('retainOnly drops unknown types', () {
      final r = Rotation([
        'push',
        'old',
        'legs',
      ], next: 1).retainOnly({'push', 'pull', 'legs'});
      expect(r.order, ['push', 'legs']);
      expect(r.nextId, 'legs');
    });
  });

  group('json (setting key "rotation")', () {
    test('round trip', () {
      final r = ppl.pointAt('legs');
      final back = Rotation.fromJson(jsonDecode(jsonEncode(r.toJson())));
      expect(back, r);
      expect(r.toJson(), {
        'order': ['push', 'pull', 'legs'],
        'next': 2,
      });
      expect(rotationSettingKey, 'rotation');
    });

    test('malformed falls back to defaults; tryFromJson says null', () {
      for (final bad in <Object?>[
        null,
        'x',
        {'order': 'push'},
        {
          'order': [1, 2],
        },
        {
          'order': ['push'],
          'next': 'one',
        },
      ]) {
        expect(Rotation.tryFromJson(bad), isNull, reason: '$bad');
        expect(Rotation.fromJson(bad), Rotation.defaults(), reason: '$bad');
      }
    });

    test('missing next means 0; stored next out of range wraps', () {
      expect(
        Rotation.fromJson({
          'order': ['a', 'b'],
        }).nextId,
        'a',
      );
      expect(
        Rotation.fromJson({
          'order': ['a', 'b'],
          'next': 3,
        }).nextId,
        'b',
      );
    });
  });
}
